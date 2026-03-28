import { useCallback, useEffect, useMemo, useState } from 'react'
import { useConnection } from '@evefrontier/dapp-kit'
import { useCurrentAccount, useCurrentNetwork, useDAppKit } from '@mysten/dapp-kit-react'
import { SuiJsonRpcClient, getJsonRpcFullnodeUrl } from '@mysten/sui/jsonRpc'
import { Transaction } from '@mysten/sui/transactions'
import './App.css'

const EVE_DECIMALS = 9n
const EVE_SCALE = 10n ** EVE_DECIMALS
const DEFAULT_EVE_TYPE =
  '0xf0446b93345c1118f21239d7ac58fb82d005219b2016e100f074e4d17162a465::EVE::EVE'

const STATE_LABELS = {
  0: '售票中',
  1: '已开奖',
  2: '已结算',
  3: '已取消',
}

function shortAddress(value) {
  if (!value) return '--'
  if (value.length <= 14) return value
  return `${value.slice(0, 8)}...${value.slice(-6)}`
}

function normalizeId(value) {
  return typeof value === 'string' ? value.toLowerCase() : ''
}

function objectData(entry) {
  return entry?.data ?? entry ?? null
}

function objectId(entry) {
  return objectData(entry)?.objectId ?? null
}

function objectType(entry) {
  return objectData(entry)?.type ?? objectData(entry)?.content?.type ?? null
}

function objectFields(entry) {
  return objectData(entry)?.content?.fields ?? objectData(entry)?.fields ?? null
}

function readField(value, key) {
  if (value == null) return null
  if (typeof value === 'object' && key in value) return value[key]
  if (typeof value === 'object' && value.fields && key in value.fields) return value.fields[key]
  return null
}

function asVector(value) {
  if (Array.isArray(value)) return value
  if (Array.isArray(value?.vec)) return value.vec
  if (Array.isArray(value?.fields?.vec)) return value.fields.vec
  if (Array.isArray(value?.fields?.contents)) return value.fields.contents
  if (Array.isArray(value?.fields?.items)) return value.fields.items
  return []
}

function unwrapOption(value) {
  const vec = asVector(value)
  return vec[0] ?? null
}

function toBigInt(value) {
  if (typeof value === 'bigint') return value
  if (typeof value === 'number') return BigInt(value)
  if (typeof value === 'string' && value.trim()) return BigInt(value)
  return 0n
}

function toNumber(value, fallback = 0) {
  if (typeof value === 'number') return value
  if (typeof value === 'bigint') return Number(value)
  if (typeof value === 'string' && value !== '') return Number(value)
  return fallback
}

function normalizeString(value) {
  if (value == null) return ''
  if (typeof value === 'string') return value
  const bytes = readField(value, 'bytes')
  if (typeof bytes === 'string') return bytes
  return String(value)
}

function parseEveAmount(input) {
  const normalized = String(input ?? '').trim()
  if (!normalized) return 0n
  if (!/^\d+(\.\d+)?$/.test(normalized)) {
    throw new Error('EVE 金额格式无效，请输入十进制数字')
  }
  const [wholePart, fractionPart = ''] = normalized.split('.')
  const paddedFraction = `${fractionPart}000000000`.slice(0, 9)
  return BigInt(wholePart) * EVE_SCALE + BigInt(paddedFraction)
}

function formatEveAmount(raw) {
  const amount = toBigInt(raw)
  const whole = amount / EVE_SCALE
  const fraction = (amount % EVE_SCALE).toString().padStart(9, '0').replace(/0+$/, '')
  return fraction ? `${whole}.${fraction} EVE` : `${whole} EVE`
}

function bytesToHex(value) {
  if (typeof value === 'string' && value.startsWith('0x')) return value
  const vec = asVector(value)
  if (!vec.length) return '--'
  return `0x${vec
    .map((item) => {
      const next = typeof item === 'object' ? item?.value ?? 0 : item
      return Number(next).toString(16).padStart(2, '0')
    })
    .join('')}`
}

function extractDigest(result) {
  return result?.digest ?? result?.Transaction?.digest ?? result?.TransactionBlock?.digest ?? ''
}

function coerceMoveValue(value) {
  if (value == null) return ''
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'bigint') return value
  if (typeof value === 'object') {
    if ('value' in value) return coerceMoveValue(value.value)
    if ('fields' in value) return coerceMoveValue(value.fields.value ?? value.fields.id ?? value.fields.bytes)
  }
  return ''
}

function parseWinner(rawWinner) {
  if (!rawWinner) return null
  const winner = rawWinner?.fields ?? rawWinner
  const player = String(coerceMoveValue(winner.player ?? winner.winner) || '')
  const characterId = String(coerceMoveValue(winner.character_id ?? winner.winner_character_id) || '')
  const ticketNumber = toNumber(winner.ticket_number ?? winner.winning_ticket)
  const ticketHash = bytesToHex(winner.ticket_hash ?? winner.winning_ticket_hash)
  if (!player && !characterId && !ticketNumber && ticketHash === '--') return null
  return {
    player,
    characterId,
    ticketNumber,
    ticketHash,
  }
}

function parseGameObject(response) {
  const fields = response?.data?.content?.fields
  if (!fields) return null
  const saleProceeds =
    readField(fields.sale_proceeds, 'value') ?? readField(fields.sale_proceeds, 'balance') ?? '0'
  const winningTicketValue = unwrapOption(fields.winning_ticket)

  return {
    objectId: response.data.objectId,
    storageUnitId: fields.storage_unit_id,
    creator: fields.creator,
    creatorCharacterId: fields.creator_character_id,
    title: normalizeString(fields.title),
    ticketPrice: fields.ticket_price ?? '0',
    totalTickets: toNumber(fields.total_tickets),
    soldTickets: toNumber(fields.sold_tickets),
    prizeTypeId: fields.prize_type_id ?? '0',
    prizeQuantity: toNumber(fields.prize_quantity),
    prizeLocked: unwrapOption(fields.prize) != null,
    saleProceeds,
    state: toNumber(fields.state),
    winningTicket: winningTicketValue == null ? null : toNumber(winningTicketValue),
    winner: parseWinner(unwrapOption(fields.winner)),
  }
}

async function fetchAllEvents(client, query, limit = 100) {
  const results = []
  let cursor = null
  while (true) {
    const page = await client.queryEvents({
      query,
      cursor,
      limit,
      order: 'descending',
    })
    results.push(...page.data)
    if (!page.hasNextPage || !page.nextCursor) break
    cursor = page.nextCursor
  }
  return results
}

function mergeWinner(primaryWinner, fallbackWinner) {
  if (!primaryWinner) return fallbackWinner ?? null
  if (!fallbackWinner) return primaryWinner
  return {
    player: primaryWinner.player || fallbackWinner.player,
    characterId: primaryWinner.characterId || fallbackWinner.characterId,
    ticketNumber: primaryWinner.ticketNumber || fallbackWinner.ticketNumber,
    ticketHash:
      primaryWinner.ticketHash && primaryWinner.ticketHash !== '--'
        ? primaryWinner.ticketHash
        : fallbackWinner.ticketHash,
  }
}

async function fetchWinnerSnapshots(client, packageId) {
  if (!client || !packageId) return new Map()

  const [drawnEvents, claimedEvents] = await Promise.all([
    fetchAllEvents(client, {
      MoveEventType: `${packageId}::sweepstakes::WinnerDrawnEvent`,
    }),
    fetchAllEvents(client, {
      MoveEventType: `${packageId}::sweepstakes::PrizeClaimedEvent`,
    }),
  ])

  const winners = new Map()

  drawnEvents.forEach((event) => {
    const parsed = event?.parsedJson ?? null
    const gameId = String(coerceMoveValue(parsed?.game_id) || '')
    if (!gameId) return
    winners.set(gameId, parseWinner(parsed))
  })

  claimedEvents.forEach((event) => {
    const parsed = event?.parsedJson ?? null
    const gameId = String(coerceMoveValue(parsed?.game_id) || '')
    if (!gameId) return
    winners.set(gameId, mergeWinner(winners.get(gameId) ?? null, parseWinner(parsed)))
  })

  return winners
}

async function fetchGames(client, packageId) {
  if (!client || !packageId) return []
  const [page, winnerSnapshots] = await Promise.all([
    client.queryEvents({
      query: { MoveEventType: `${packageId}::sweepstakes::GameCreatedEvent` },
      limit: 50,
      order: 'descending',
    }),
    fetchWinnerSnapshots(client, packageId),
  ])
  const ids = [...new Set(page.data.map((item) => item.parsedJson?.game_id).filter(Boolean))]
  if (!ids.length) return []
  const objects = await client.multiGetObjects({ ids, options: { showContent: true } })
  return objects
    .map((response) => {
      const game = parseGameObject(response)
      if (!game) return null
      const winnerFallback = winnerSnapshots.get(game.objectId) ?? null
      if (winnerFallback) {
        game.winner = mergeWinner(game.winner, winnerFallback)
        if (game.winningTicket == null && winnerFallback.ticketNumber) {
          game.winningTicket = winnerFallback.ticketNumber
        }
      }
      return game
    })
    .filter(Boolean)
}

async function fetchAllOwnedObjects(client, owner, filter) {
  const results = []
  let cursor = null
  while (true) {
    const page = await client.getOwnedObjects({
      owner,
      cursor,
      filter,
      options: { showType: true, showContent: true },
    })
    results.push(...page.data)
    if (!page.hasNextPage || !page.nextCursor) break
    cursor = page.nextCursor
  }
  return results
}

async function detectResources(client, worldPackageId, walletAddress) {
  if (!client || !worldPackageId || !walletAddress) return []
  const playerProfileType = `${worldPackageId}::character::PlayerProfile`
  const storageUnitOwnerCapType = `${worldPackageId}::access::OwnerCap<${worldPackageId}::storage_unit::StorageUnit>`
  const profiles = await fetchAllOwnedObjects(client, walletAddress, { StructType: playerProfileType })
  const characterIds = [...new Set(profiles.map((item) => objectFields(item)?.character_id).filter(Boolean))]
  if (!characterIds.length) return []

  const characters = await client.multiGetObjects({
    ids: characterIds,
    options: { showContent: true, showType: true },
  })

  return Promise.all(
    characters
      .map((characterObject) => {
        const fields = objectFields(characterObject)
        return fields
          ? {
              characterId: objectId(characterObject),
              characterOwnerCapId: fields.owner_cap_id ?? '',
              characterAddress: fields.character_address ?? '',
            }
          : null
      })
      .filter(Boolean)
      .map(async (resource) => {
        const ownedByCharacter = await fetchAllOwnedObjects(client, resource.characterId)
        const storageUnits = ownedByCharacter
          .filter((item) => objectType(item) === storageUnitOwnerCapType)
          .map((item) => ({
            storageUnitOwnerCapId: objectId(item),
            storageUnitId: objectFields(item)?.authorized_object_id ?? '',
          }))
          .filter((item) => item.storageUnitOwnerCapId && item.storageUnitId)

        return { ...resource, storageUnits }
      }),
  )
}

async function fetchAllCoins(client, owner, coinType) {
  const results = []
  let cursor = null
  while (true) {
    const page = await client.getCoins({ owner, coinType, cursor })
    results.push(...page.data)
    if (!page.hasNextPage || !page.nextCursor) break
    cursor = page.nextCursor
  }
  return results
}

async function selectPaymentCoin(tx, client, owner, coinType, requiredAmount) {
  const coins = await fetchAllCoins(client, owner, coinType)
  let total = 0n
  const selected = []

  for (const coinInfo of coins) {
    selected.push(coinInfo)
    total += BigInt(coinInfo.balance)
    if (total >= requiredAmount) break
  }

  if (total < requiredAmount) {
    throw new Error(`EVE 余额不足，至少需要 ${formatEveAmount(requiredAmount)}`)
  }

  const primary = tx.object(selected[0].coinObjectId)
  if (selected.length > 1) {
    tx.mergeCoins(primary, selected.slice(1).map((coinInfo) => tx.object(coinInfo.coinObjectId)))
  }
  if (selected.length === 1 && BigInt(selected[0].balance) === requiredAmount) {
    return primary
  }

  const [paymentCoin] = tx.splitCoins(primary, [tx.pure.u64(requiredAmount.toString())])
  return paymentCoin
}
function App() {
  const { handleConnect, handleDisconnect, hasEveVault } = useConnection()
  const account = useCurrentAccount()
  const currentNetwork = useCurrentNetwork()
  const dAppKit = useDAppKit()

  const [sweepstakesPackageId, setSweepstakesPackageId] = useState(
    import.meta.env.VITE_SWEEPSTAKES_PACKAGE_ID ?? '',
  )
  const [worldPackageId, setWorldPackageId] = useState(import.meta.env.VITE_WORLD_PACKAGE_ID ?? '')
  const [eveType, setEveType] = useState(import.meta.env.VITE_EVE_TYPE ?? DEFAULT_EVE_TYPE)

  const [games, setGames] = useState([])
  const [resources, setResources] = useState([])
  const [selectedGameId, setSelectedGameId] = useState('')
  const [configExpanded, setConfigExpanded] = useState(false)
  const [loadingGames, setLoadingGames] = useState(false)
  const [loadingResources, setLoadingResources] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [feedback, setFeedback] = useState('')
  const [error, setError] = useState('')

  const [createForm, setCreateForm] = useState({
    title: 'Sweepstakes Lottery',
    storageUnitId: '',
    creatorCharacterId: '',
    storageUnitOwnerCapId: '',
    prizeTypeId: '',
    prizeQuantity: '1',
    ticketPrice: '1',
    totalTickets: '10',
  })
  const [buyForm, setBuyForm] = useState({ gameId: '', buyerCharacterId: '', ticketCount: '1' })
  const [drawForm, setDrawForm] = useState({ gameId: '' })
  const [claimForm, setClaimForm] = useState({ gameId: '', storageUnitId: '', winnerCharacterId: '' })
  const [cancelForm, setCancelForm] = useState({ gameId: '', storageUnitId: '', creatorCharacterId: '' })

  const envNetwork = import.meta.env.VITE_SUI_NETWORK || 'testnet'
  const rpcNetwork = typeof currentNetwork === 'string' && currentNetwork ? currentNetwork : envNetwork

  const readClient = useMemo(
    () => new SuiJsonRpcClient({ url: getJsonRpcFullnodeUrl(rpcNetwork), network: rpcNetwork }),
    [rpcNetwork],
  )

  const ready = Boolean(account?.address && sweepstakesPackageId && worldPackageId && eveType)
  const activeGames = useMemo(
    () => games.filter((item) => item.state === 0),
    [games],
  )
  const currentGame = useMemo(
    () => activeGames.find((item) => item.objectId === selectedGameId) ?? activeGames[0] ?? null,
    [activeGames, selectedGameId],
  )

  const applyDetectedCharacter = useCallback((resource) => {
    setCreateForm((current) => ({
      ...current,
      creatorCharacterId: resource.characterId || current.creatorCharacterId,
    }))
    setBuyForm((current) => ({
      ...current,
      buyerCharacterId: resource.characterId || current.buyerCharacterId,
    }))
    setClaimForm((current) => ({
      ...current,
      winnerCharacterId: resource.characterId || current.winnerCharacterId,
    }))
    setCancelForm((current) => ({
      ...current,
      creatorCharacterId: resource.characterId || current.creatorCharacterId,
    }))
  }, [])

  const applyDetectedStorageUnit = useCallback((resource, storageUnit) => {
    setCreateForm((current) => ({
      ...current,
      storageUnitId: storageUnit.storageUnitId || current.storageUnitId,
      creatorCharacterId: resource.characterId || current.creatorCharacterId,
      storageUnitOwnerCapId: storageUnit.storageUnitOwnerCapId || current.storageUnitOwnerCapId,
    }))
  }, [])

  const refreshGames = useCallback(async () => {
    if (!sweepstakesPackageId) {
      setGames([])
      return
    }
    setLoadingGames(true)
    try {
      setGames(await fetchGames(readClient, sweepstakesPackageId))
    } catch (refreshError) {
      setError(refreshError.message ?? '读取抽奖列表失败')
    } finally {
      setLoadingGames(false)
    }
  }, [sweepstakesPackageId, readClient])

  const refreshResources = useCallback(async () => {
    if (!account?.address || !worldPackageId) {
      setResources([])
      return
    }
    setLoadingResources(true)
    try {
      setResources(await detectResources(readClient, worldPackageId, account.address))
    } catch (refreshError) {
      setError(refreshError.message ?? '读取 Character / StorageUnit / OwnerCap 失败')
    } finally {
      setLoadingResources(false)
    }
  }, [account?.address, readClient, worldPackageId])

  useEffect(() => {
    void refreshGames()
  }, [refreshGames])

  useEffect(() => {
    void refreshResources()
  }, [refreshResources])

  useEffect(() => {
    if (!activeGames.length) {
      setSelectedGameId('')
      return
    }
    const exists = activeGames.some((item) => item.objectId === selectedGameId)
    if (!selectedGameId || !exists) {
      setSelectedGameId(activeGames[0].objectId)
    }
  }, [activeGames, selectedGameId])

  useEffect(() => {
    if (!currentGame) {
      setBuyForm((current) => ({ ...current, gameId: '' }))
      return
    }

    setBuyForm((current) => ({ ...current, gameId: currentGame.objectId }))
    setDrawForm({ gameId: currentGame.objectId })
    setClaimForm((current) => ({
      ...current,
      gameId: currentGame.objectId,
      storageUnitId: currentGame.storageUnitId,
      winnerCharacterId: currentGame.winner?.characterId ?? current.winnerCharacterId,
    }))
    setCancelForm({
      gameId: currentGame.objectId,
      storageUnitId: currentGame.storageUnitId,
      creatorCharacterId: currentGame.creatorCharacterId,
    })
  }, [currentGame])

  useEffect(() => {
    if (!resources.length) return
    const primaryResource = resources[0]
    const primaryStorageUnit = primaryResource.storageUnits[0] ?? null

    setCreateForm((current) => ({
      ...current,
      creatorCharacterId: current.creatorCharacterId || primaryResource.characterId || '',
      storageUnitId: current.storageUnitId || primaryStorageUnit?.storageUnitId || '',
      storageUnitOwnerCapId: current.storageUnitOwnerCapId || primaryStorageUnit?.storageUnitOwnerCapId || '',
    }))
    setBuyForm((current) => ({
      ...current,
      buyerCharacterId: current.buyerCharacterId || primaryResource.characterId || '',
    }))
    setClaimForm((current) => ({
      ...current,
      winnerCharacterId: current.winnerCharacterId || primaryResource.characterId || '',
    }))
    setCancelForm((current) => ({
      ...current,
      creatorCharacterId: current.creatorCharacterId || primaryResource.characterId || '',
    }))
  }, [resources])

  const fillCreateFromGame = useCallback((game) => {
    setCreateForm((current) => ({
      ...current,
      storageUnitId: game.storageUnitId || current.storageUnitId,
      creatorCharacterId: game.creatorCharacterId || current.creatorCharacterId,
    }))
  }, [])

  const submitTransaction = useCallback(
    async (builder, successMessage) => {
      if (!ready) {
        throw new Error('请先连接钱包，并配置 Sweepstakes / World / EVE 参数')
      }

      setSubmitting(true)
      setError('')
      setFeedback('')

      try {
        const transaction = await builder()
        const result = await dAppKit.signAndExecuteTransaction({ transaction })
        const digest = extractDigest(result)
        setFeedback(`${successMessage}${digest ? `｜Digest: ${digest}` : ''}`)
        await refreshGames()
      } catch (submitError) {
        setError(submitError.message ?? '交易失败')
      } finally {
        setSubmitting(false)
      }
    },
    [dAppKit, ready, refreshGames],
  )

  const handleCreateGame = useCallback(async (event) => {
    event.preventDefault()

    await submitTransaction(async () => {
      const tx = new Transaction()
      const storageUnitType = `${worldPackageId}::storage_unit::StorageUnit`

      const [storageUnitOwnerCap, receipt] = tx.moveCall({
        target: `${worldPackageId}::character::borrow_owner_cap`,
        typeArguments: [storageUnitType],
        arguments: [tx.object(createForm.creatorCharacterId), tx.object(createForm.storageUnitOwnerCapId)],
      })

      const [game, returnedCap] = tx.moveCall({
        target: `${sweepstakesPackageId}::sweepstakes::create_game`,
        arguments: [
          tx.object(createForm.storageUnitId),
          tx.object(createForm.creatorCharacterId),
          storageUnitOwnerCap,
          tx.pure.string(createForm.title),
          tx.pure.u64(String(createForm.prizeTypeId)),
          tx.pure.u32(Number(createForm.prizeQuantity)),
          tx.pure.u64(parseEveAmount(createForm.ticketPrice).toString()),
          tx.pure.u64(String(createForm.totalTickets)),
        ],
      })

      tx.moveCall({
        target: `${worldPackageId}::character::return_owner_cap`,
        typeArguments: [storageUnitType],
        arguments: [tx.object(createForm.creatorCharacterId), returnedCap, receipt],
      })

      tx.moveCall({
        target: `${sweepstakesPackageId}::sweepstakes::share_game`,
        arguments: [game],
      })

      return tx
    }, '抽奖创建成功')
  }, [createForm, sweepstakesPackageId, submitTransaction, worldPackageId])

  const submitBuyTickets = useCallback(async (gameId, buyerCharacterId, ticketCountValue) => {
    await submitTransaction(async () => {
      const tx = new Transaction()
      const normalizedTicketCount = String(ticketCountValue ?? '').trim()
      if (!/^\d+$/.test(normalizedTicketCount) || Number(normalizedTicketCount) <= 0) {
        throw new Error('购票张数必须是大于 0 的整数')
      }
      if (!buyerCharacterId) {
        throw new Error('请先填写购票 Character ID')
      }

      const ticketCount = BigInt(normalizedTicketCount)
      const game = games.find((item) => item.objectId === gameId)
      if (!game) throw new Error('未找到对应游戏，请先刷新列表')

      const requiredAmount = toBigInt(game.ticketPrice) * ticketCount
      const paymentCoin = await selectPaymentCoin(tx, readClient, account.address, eveType, requiredAmount)

      tx.moveCall({
        target: `${sweepstakesPackageId}::sweepstakes::buy_tickets`,
        arguments: [
          tx.object(gameId),
          tx.object(buyerCharacterId),
          paymentCoin,
          tx.pure.u64(ticketCount.toString()),
        ],
      })

      return tx
    }, '购票成功')
  }, [account?.address, eveType, games, sweepstakesPackageId, readClient, submitTransaction])

  const handleBuyTickets = useCallback(async (event) => {
    event.preventDefault()
    await submitBuyTickets(buyForm.gameId, buyForm.buyerCharacterId, buyForm.ticketCount)
  }, [buyForm.buyerCharacterId, buyForm.gameId, buyForm.ticketCount, submitBuyTickets])

  const handleQuickBuyCurrentGame = useCallback(async () => {
    if (!currentGame) return
    await submitBuyTickets(currentGame.objectId, buyForm.buyerCharacterId, buyForm.ticketCount)
  }, [buyForm.buyerCharacterId, buyForm.ticketCount, currentGame, submitBuyTickets])

  const handleDrawWinner = useCallback(async (event) => {
    event.preventDefault()

    await submitTransaction(async () => {
      const tx = new Transaction()
      tx.moveCall({
        target: `${sweepstakesPackageId}::sweepstakes::draw_winner`,
        arguments: [tx.object(drawForm.gameId), tx.object.random()],
      })
      return tx
    }, '开奖成功')
  }, [drawForm.gameId, sweepstakesPackageId, submitTransaction])

  const handleClaimPrize = useCallback(async (event) => {
    event.preventDefault()

    await submitTransaction(async () => {
      const tx = new Transaction()
      tx.moveCall({
        target: `${sweepstakesPackageId}::sweepstakes::claim_prize`,
        arguments: [tx.object(claimForm.gameId), tx.object(claimForm.storageUnitId), tx.object(claimForm.winnerCharacterId)],
      })
      return tx
    }, '领奖成功')
  }, [claimForm, sweepstakesPackageId, submitTransaction])

  const handleCancelGame = useCallback(async (event) => {
    event.preventDefault()

    await submitTransaction(async () => {
      const tx = new Transaction()
      tx.moveCall({
        target: `${sweepstakesPackageId}::sweepstakes::cancel_game`,
        arguments: [tx.object(cancelForm.gameId), tx.object(cancelForm.storageUnitId), tx.object(cancelForm.creatorCharacterId)],
      })
      return tx
    }, '取消并退款成功')
  }, [cancelForm, sweepstakesPackageId, submitTransaction])
  return (
    <div className="page">
      <section className="hero-card">
        <div className="hero-copy">
          <p className="eyebrow">Sweepstakes</p>
          <h1>
            Storage Unit
            <br />
            抽奖系统
          </h1>
          <p className="hero-text">
            奖品先锁定在链上，售罄后使用 Sui 随机数开奖；现在可在进行中的抽奖和当前详情里直接完成购票操作。
          </p>
        </div>

        <div className="wallet-box">
          <div className="actions">
            <button className="primary-button" type="button" onClick={() => (account ? handleDisconnect() : handleConnect())}>
              {account ? `断开 ${shortAddress(account.address)}` : '连接钱包'}
            </button>
          </div>
          <div className="wallet-meta">
            <strong>{account?.address ? shortAddress(account.address) : '--'}</strong>
            <span className="subtle">Network: {rpcNetwork}</span>
            <span className="subtle">EVE Vault: {hasEveVault ? 'OK' : 'Missing'}</span>
          </div>
        </div>
      </section>

      <section className="card">
        <div className="section-header">
          <h2>基础配置</h2>
          <button className="ghost-button" type="button" onClick={() => setConfigExpanded((current) => !current)}>
            {configExpanded ? '收起配置' : '展开配置'}
          </button>
        </div>

        <div className="stats-grid compact">
          <div><span>当前网络</span><strong>{rpcNetwork}</strong></div>
          <div><span>抽奖合约 Package</span><strong className="mono">{shortAddress(sweepstakesPackageId || '--')}</strong></div>
          <div><span>World Package</span><strong className="mono">{shortAddress(worldPackageId || '--')}</strong></div>
          <div><span>EVE Type</span><strong className="mono">{shortAddress(eveType || '--')}</strong></div>
        </div>

        {configExpanded ? (
          <div className="collapsible-body">
            <div className="grid two config-grid">
              <label>
                <span>Sweepstakes Package ID</span>
                <input value={sweepstakesPackageId} onChange={(event) => setSweepstakesPackageId(event.target.value.trim())} placeholder="0x..." />
              </label>
              <label>
                <span>World Package ID</span>
                <input value={worldPackageId} onChange={(event) => setWorldPackageId(event.target.value.trim())} placeholder="0x..." />
              </label>
              <label className="full-width">
                <span>EVE Coin Type</span>
                <input value={eveType} onChange={(event) => setEveType(event.target.value.trim())} />
              </label>
            </div>
          </div>
        ) : null}

        {feedback ? <div className="feedback success">{feedback}</div> : null}
        {error ? <div className="feedback error">{error}</div> : null}
      </section>

      <section className="card">
        <div className="section-header">
          <h2>自动查询 Character / StorageUnit / OwnerCap</h2>
          <div className="actions">
            <button className="ghost-button" type="button" onClick={refreshResources} disabled={loadingResources || submitting}>
              {loadingResources ? '读取中...' : '刷新自动查询'}
            </button>
          </div>
        </div>

        {!account?.address ? (
          <div className="empty-state">请先连接钱包，再自动读取该钱包下的 Character、SU 与对应 OwnerCap。</div>
        ) : !resources.length ? (
          <div className="empty-state">当前钱包下未读取到可用的 Character / StorageUnit / OwnerCap。</div>
        ) : (
          <div className="game-list">
            {resources.map((resource) => (
              <article className="game-card" key={resource.characterId}>
                <div className="game-card-head">
                  <div>
                    <p className="card-kicker">Detected Character</p>
                    <h3>{shortAddress(resource.characterAddress || account.address)}</h3>
                    <p className="mono subtle">{resource.characterId}</p>
                  </div>
                  <span className="badge state-ledger">Character</span>
                </div>

                <div className="stats-grid">
                  <div><span>Character ID</span><strong className="mono">{resource.characterId}</strong></div>
                  <div><span>Character OwnerCap</span><strong className="mono">{resource.characterOwnerCapId || '--'}</strong></div>
                  <div><span>Character Address</span><strong>{shortAddress(resource.characterAddress)}</strong></div>
                  <div><span>可用 SU 数量</span><strong>{resource.storageUnits.length}</strong></div>
                </div>

                <div className="actions">
                  <button className="ghost-button" type="button" onClick={() => applyDetectedCharacter(resource)}>
                    带入角色字段
                  </button>
                </div>

                {resource.storageUnits.length ? (
                  <div className="ledger-table">
                    <div className="ledger-row ledger-head">
                      <span>Storage Unit ID</span>
                      <span>StorageUnit OwnerCap ID</span>
                      <span>操作</span>
                      <span>说明</span>
                    </div>
                    {resource.storageUnits.map((storageUnit) => (
                      <div className="ledger-row" key={storageUnit.storageUnitOwnerCapId}>
                        <span className="mono wrap">{storageUnit.storageUnitId}</span>
                        <span className="mono wrap">{storageUnit.storageUnitOwnerCapId}</span>
                        <span>
                          <button
                            className="ghost-button"
                            type="button"
                            onClick={() => applyDetectedStorageUnit(resource, storageUnit)}
                          >
                            带入创建抽奖
                          </button>
                        </span>
                        <span className="subtle">自动填充 SU、创建角色、SU OwnerCap；仍可手动修改</span>
                      </div>
                    ))}
                  </div>
                ) : (
                  <div className="empty-state">这个 Character 当前未检测到可管理的 Storage Unit OwnerCap。</div>
                )}
              </article>
            ))}
          </div>
        )}
      </section>

      <section className="card">
        <div className="section-header">
          <h2>进行中的抽奖</h2>
          <div className="actions">
            <span className="subtle">来源：`GameCreatedEvent` + `multiGetObjects`</span>
            <button className="ghost-button" type="button" onClick={refreshGames} disabled={loadingGames || submitting}>
              {loadingGames ? '刷新抽奖中...' : '刷新抽奖'}
            </button>
          </div>
        </div>

        {!activeGames.length ? (
          <div className="empty-state">当前未读取到进行中的抽奖对象。</div>
        ) : (
          <div className="game-list">
            {activeGames.map((game) => {
              const progress = game.totalTickets ? Math.min(100, Math.round((game.soldTickets / game.totalTickets) * 100)) : 0
              const isSelected = currentGame?.objectId === game.objectId

              return (
                <article className={`game-card ${isSelected ? 'selected' : ''}`} key={game.objectId}>
                  <div className="game-card-head">
                    <div>
                      <p className="card-kicker">Lottery Game</p>
                      <h3>{game.title || 'Untitled Lottery'}</h3>
                      <p className="mono subtle">{game.objectId}</p>
                    </div>
                    <span className={`badge state-${game.state}`}>{STATE_LABELS[game.state] ?? `状态 ${game.state}`}</span>
                  </div>

                  <div className="stats-grid">
                    <div><span>Storage Unit</span><strong>{shortAddress(game.storageUnitId)}</strong></div>
                    <div><span>创建者</span><strong>{shortAddress(game.creator)}</strong></div>
                    <div><span>票价</span><strong>{formatEveAmount(game.ticketPrice)}</strong></div>
                    <div><span>奖品</span><strong>{`${game.prizeQuantity} × ${game.prizeTypeId}`}</strong></div>
                    <div><span>票款余额</span><strong>{formatEveAmount(game.saleProceeds)}</strong></div>
                    <div><span>奖品锁定</span><strong>{game.prizeLocked ? '是' : '否'}</strong></div>
                    <div><span>中奖票号</span><strong>{game.winningTicket ?? '--'}</strong></div>
                    <div><span>中奖彩票根</span><strong className="mono">{game.winner?.ticketHash ? shortAddress(game.winner.ticketHash) : '--'}</strong></div>
                  </div>

                  <div className="progress-box">
                    <div className="progress-meta"><span>售票进度</span><strong>{game.soldTickets}/{game.totalTickets}</strong></div>
                    <div className="progress-track"><div className="progress-fill" style={{ width: `${progress}%` }} /></div>
                  </div>

                  <div className="actions">
                    <button className="primary-button" type="button" onClick={() => setSelectedGameId(game.objectId)}>{isSelected ? '当前查看中' : '查看详情'}</button>
                    <button className="ghost-button" type="button" onClick={() => setBuyForm((current) => ({ ...current, gameId: game.objectId }))}>填入购票</button>
                    <button className="ghost-button" type="button" onClick={() => setDrawForm({ gameId: game.objectId })}>填入开奖</button>
                    <button className="ghost-button" type="button" onClick={() => setClaimForm((current) => ({ ...current, gameId: game.objectId, storageUnitId: game.storageUnitId, winnerCharacterId: game.winner?.characterId ?? current.winnerCharacterId }))}>填入领奖</button>
                    <button className="ghost-button" type="button" onClick={() => setCancelForm({ gameId: game.objectId, storageUnitId: game.storageUnitId, creatorCharacterId: game.creatorCharacterId })}>填入取消</button>
                    <button className="ghost-button" type="button" onClick={() => fillCreateFromGame(game)}>带入创建</button>
                  </div>
                </article>
              )
            })}
          </div>
        )}
      </section>

      {currentGame ? (
        <>
          <section className="card">
            <div className="section-header">
              <h2>当前抽奖详情</h2>
              <span className="subtle">集中查看当前选中游戏状态，并可直接填写购票张数。</span>
            </div>
            <div className="stats-grid">
              <div><span>游戏 ID</span><strong className="mono">{currentGame.objectId}</strong></div>
              <div><span>Storage Unit ID</span><strong className="mono">{currentGame.storageUnitId}</strong></div>
              <div><span>创建角色</span><strong className="mono">{currentGame.creatorCharacterId}</strong></div>
              <div><span>当前状态</span><strong>{STATE_LABELS[currentGame.state] ?? currentGame.state}</strong></div>
              <div><span>售出票数</span><strong>{currentGame.soldTickets}</strong></div>
              <div><span>中奖地址</span><strong>{currentGame.winner ? shortAddress(currentGame.winner.player) : '--'}</strong></div>
              <div><span>中奖角色</span><strong className="mono">{currentGame.winner?.characterId || '--'}</strong></div>
              <div><span>完整中奖彩票根</span><strong className="mono wrap">{currentGame.winner?.ticketHash || '--'}</strong></div>
            </div>
            <div className="quick-buy-panel">
              <label>
                <span>当前购票 Character ID</span>
                <input
                  value={buyForm.buyerCharacterId}
                  onChange={(event) => setBuyForm((current) => ({ ...current, buyerCharacterId: event.target.value.trim() }))}
                  placeholder="0x..."
                />
              </label>
              <label>
                <span>购买张数</span>
                <input
                  type="number"
                  min="1"
                  step="1"
                  value={buyForm.ticketCount}
                  onChange={(event) => setBuyForm((current) => ({ ...current, ticketCount: event.target.value.trim() }))}
                />
              </label>
              <div className="quick-buy-summary">
                <span>本次支付</span>
                <strong>
                  {/^\d+$/.test(buyForm.ticketCount || '')
                    ? formatEveAmount(toBigInt(currentGame.ticketPrice) * BigInt(buyForm.ticketCount || '0'))
                    : '--'}
                </strong>
                <div className="subtle">按当前选中抽奖的单张票价自动计算。</div>
              </div>
              <button className="primary-button" type="button" disabled={!ready || submitting} onClick={handleQuickBuyCurrentGame}>
                购买当前抽奖
              </button>
            </div>
          </section>
        </>
      ) : null}

      <section className="forms-grid">
        <form className="card" onSubmit={handleCreateGame}>
          <div className="section-header"><h2>1. 创建抽奖</h2><span className="subtle">创建者锁定奖品</span></div>
          <label><span>标题</span><input value={createForm.title} onChange={(event) => setCreateForm((current) => ({ ...current, title: event.target.value }))} /></label>
          <label><span>Storage Unit ID</span><input value={createForm.storageUnitId} onChange={(event) => setCreateForm((current) => ({ ...current, storageUnitId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <label><span>创建者 Character ID</span><input value={createForm.creatorCharacterId} onChange={(event) => setCreateForm((current) => ({ ...current, creatorCharacterId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <label><span>StorageUnit OwnerCap ID</span><input value={createForm.storageUnitOwnerCapId} onChange={(event) => setCreateForm((current) => ({ ...current, storageUnitOwnerCapId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <div className="grid two">
            <label><span>奖品 Type ID</span><input value={createForm.prizeTypeId} onChange={(event) => setCreateForm((current) => ({ ...current, prizeTypeId: event.target.value.trim() }))} placeholder="77810" /></label>
            <label><span>奖品数量</span><input value={createForm.prizeQuantity} onChange={(event) => setCreateForm((current) => ({ ...current, prizeQuantity: event.target.value.trim() }))} /></label>
          </div>
          <div className="grid two">
            <label><span>单张票价（EVE）</span><input value={createForm.ticketPrice} onChange={(event) => setCreateForm((current) => ({ ...current, ticketPrice: event.target.value.trim() }))} /></label>
            <label><span>总票数</span><input value={createForm.totalTickets} onChange={(event) => setCreateForm((current) => ({ ...current, totalTickets: event.target.value.trim() }))} /></label>
          </div>
          <button className="primary-button" type="submit" disabled={!ready || submitting}>创建并共享抽奖</button>
        </form>

        <form className="card" onSubmit={handleBuyTickets}>
          <div className="section-header"><h2>2. 购票</h2><span className="subtle">自动按游戏票价扣除 EVE</span></div>
          <label>
            <span>选择抽奖</span>
            <select value={buyForm.gameId} onChange={(event) => setBuyForm((current) => ({ ...current, gameId: event.target.value }))}>
              {!activeGames.length ? <option value="">暂无进行中的抽奖</option> : null}
              {activeGames.map((game) => (
                <option key={game.objectId} value={game.objectId}>
                  {`${game.title || 'Untitled Lottery'} ｜ ${formatEveAmount(game.ticketPrice)} ｜ ${game.soldTickets}/${game.totalTickets}`}
                </option>
              ))}
            </select>
          </label>
          <label><span>购票 Character ID</span><input value={buyForm.buyerCharacterId} onChange={(event) => setBuyForm((current) => ({ ...current, buyerCharacterId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <label><span>购票张数</span><input type="number" min="1" step="1" value={buyForm.ticketCount} onChange={(event) => setBuyForm((current) => ({ ...current, ticketCount: event.target.value.trim() }))} /></label>
          <button className="primary-button" type="submit" disabled={!ready || submitting || !buyForm.gameId}>购买彩票</button>
        </form>

        <form className="card" onSubmit={handleDrawWinner}>
          <div className="section-header"><h2>3. 开奖</h2><span className="subtle">仅售罄后可执行</span></div>
          <label><span>游戏 ID</span><input value={drawForm.gameId} onChange={(event) => setDrawForm({ gameId: event.target.value.trim() })} placeholder="0x..." /></label>
          <button className="primary-button" type="submit" disabled={!ready || submitting}>使用链上随机数开奖</button>
        </form>

        <form className="card" onSubmit={handleClaimPrize}>
          <div className="section-header"><h2>4. 领奖</h2><span className="subtle">仅中奖者可领取</span></div>
          <label><span>游戏 ID</span><input value={claimForm.gameId} onChange={(event) => setClaimForm((current) => ({ ...current, gameId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <label><span>Storage Unit ID</span><input value={claimForm.storageUnitId} onChange={(event) => setClaimForm((current) => ({ ...current, storageUnitId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <label><span>中奖 Character ID</span><input value={claimForm.winnerCharacterId} onChange={(event) => setClaimForm((current) => ({ ...current, winnerCharacterId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <button className="primary-button" type="submit" disabled={!ready || submitting}>领取奖品</button>
        </form>

        <form className="card" onSubmit={handleCancelGame}>
          <div className="section-header"><h2>5. 取消抽奖</h2><span className="subtle">未售罄前可取消并退款</span></div>
          <label><span>游戏 ID</span><input value={cancelForm.gameId} onChange={(event) => setCancelForm((current) => ({ ...current, gameId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <label><span>Storage Unit ID</span><input value={cancelForm.storageUnitId} onChange={(event) => setCancelForm((current) => ({ ...current, storageUnitId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <label><span>创建者 Character ID</span><input value={cancelForm.creatorCharacterId} onChange={(event) => setCancelForm((current) => ({ ...current, creatorCharacterId: event.target.value.trim() }))} placeholder="0x..." /></label>
          <button className="danger-button" type="submit" disabled={!ready || submitting}>取消并退款</button>
        </form>
      </section>
    </div>
  )
}

export default App
