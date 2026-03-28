/// 这是 `sweepstakes_ext/sources/sweepstakes.move` 的带中文注释阅读版，逻辑与可编译源码保持一致。
/// 这个模块实现一个绑定到 `StorageUnit` 的链上抽奖小游戏。
/// 
/// 设计目标：
/// 1. 创建者先把奖品从指定 SU 中提出，并锁进抽奖对象内部托管。
/// 2. 其他玩家使用 EVE 购票。
/// 3. 售罄后使用 Sui 链上随机数开奖。
/// 4. 中奖者再把奖品存回自己在该 SU 下的 owned inventory。
/// 5. 创建者可在未售罄前取消，系统会逐笔退款并退回奖品。
/// 
/// 这次额外增强了“票根哈希”机制：
/// - 每张票都会生成独立哈希票根。
/// - 每张票根会以动态字段的形式挂在 `LotteryGame` 下。
/// - 开奖时不再线性扫描购买区间，而是直接按中奖票号 O(1) 读取票根。
/// - 这样既便于前端展示全部票根，也规避了“随机结果影响线性扫描 gas 路径”的风险点。
/// 
/// 参考：
/// - Sui 官方随机数文档（非 public 的 entry 函数写法）
///   https://docs.sui.io/guides/developer/on-chain-primitives/randomness-onchain
/// - 仓库内 `world::storage_unit` 的扩展授权模式与 `deposit_to_owned` / `withdraw_item`
/// - 仓库内 `world::character::borrow_owner_cap` / `return_owner_cap` 的 OwnerCap 借还流程
module extension_examples::sweepstakes;

/// 引入 `String`，用于保存抽奖标题。
use std::string::String;
/// 引入 `Balance<EVE>` 相关能力，用于在共享对象内托管售票收入。
use sui::balance::{Self as balance, Balance};
/// 引入 `Coin<EVE>` 相关能力，用于接收玩家支付、找零、退款和结算。
use sui::coin::{Self as coin, Coin};
/// 引入动态字段模块，用于给每一张票生成单独的链上票根记录。
use sui::dynamic_field as df;
/// 引入事件模块，用于向前端暴露创建、出票、购票、开奖、领奖、取消等链上事件。
use sui::event;
/// 引入随机数模块，用于售罄后从全部票号中公平抽取中奖彩票。
use sui::random::{Self as random, Random};
/// 引入 BCS 和哈希模块，用于生成票根哈希。
use sui::{bcs, hash};
/// 引入 EVE 币种类型，整套抽奖都以这个币种结算。
use assets::EVE::EVE;
/// 引入访问控制模块和 `OwnerCap`，用于验证调用者确实拥有目标 StorageUnit。
use world::access::{Self as access, OwnerCap};
/// 引入 Character 模块和 `Character`，用于把操作绑定到角色并校验 sender。
use world::character::{Self as character, Character};
/// 引入 `Item`，奖品从 SU 提出后会以这个对象形式锁进抽奖对象中。
use world::inventory::Item;
/// 引入 StorageUnit 模块和 `StorageUnit`，用于提取奖品和把奖品存回角色 owned inventory。
use world::storage_unit::{Self as storage_unit, StorageUnit};

/// 错误 0：总票数必须大于 0。
#[error(code = 0)]
const ETotalTicketsMustBePositive: vector<u8> = b"Total tickets must be greater than 0";
/// 错误 1：单张票价必须大于 0。
#[error(code = 1)]
const ETicketPriceMustBePositive: vector<u8> = b"Ticket price must be greater than 0";
/// 错误 2：奖品数量必须大于 0。
#[error(code = 2)]
const EPrizeQuantityMustBePositive: vector<u8> = b"Prize quantity must be greater than 0";
/// 错误 3：只有该 StorageUnit 的真正 owner 才能创建抽奖。
#[error(code = 3)]
const EStorageUnitOwnerRequired: vector<u8> = b"Only the storage unit owner can create a lottery";
/// 错误 4：传入的 Character 必须属于当前交易发送者。
#[error(code = 4)]
const ECharacterSenderMismatch: vector<u8> = b"Character address must match the transaction sender";
/// 错误 5：当前游戏不处于售票状态。
#[error(code = 5)]
const EGameNotOpen: vector<u8> = b"Lottery game is not open";
/// 错误 6：本次购票张数必须大于 0。
#[error(code = 6)]
const ETicketCountMustBePositive: vector<u8> = b"Ticket count must be greater than 0";
/// 错误 7：剩余可售票数不足。
#[error(code = 7)]
const ETicketsSoldOut: vector<u8> = b"Not enough remaining tickets";
/// 错误 8：支付金额不足以覆盖本次购票成本。
#[error(code = 8)]
const EInsufficientPayment: vector<u8> = b"Payment is smaller than the required EVE amount";
/// 错误 9：只有创建者本人可以取消抽奖。
#[error(code = 9)]
const EOnlyCreatorCanCancel: vector<u8> = b"Only the creator can cancel the lottery";
/// 错误 10：只有售罄后才允许开奖。
#[error(code = 10)]
const ENotSoldOut: vector<u8> = b"Lottery can be drawn only after all tickets are sold";
/// 错误 11：同一场抽奖不能重复开奖。
#[error(code = 11)]
const EWinnerAlreadyDrawn: vector<u8> = b"Winner has already been drawn";
/// 错误 12：当前还没有开奖结果。
#[error(code = 12)]
const EWinnerNotDrawn: vector<u8> = b"Winner has not been drawn yet";
/// 错误 13：只有记录中的中奖者才可以领奖。
#[error(code = 13)]
const EOnlyWinnerCanClaim: vector<u8> = b"Only the recorded winner can claim the prize";
/// 错误 14：领奖时传入的 Character 与中奖快照中的角色不一致。
#[error(code = 14)]
const EWinnerCharacterMismatch: vector<u8> = b"Winner character does not match the recorded winner";
/// 错误 15：传入的 StorageUnit 与本场游戏绑定的 StorageUnit 不一致。
#[error(code = 15)]
const EStorageUnitMismatch: vector<u8> = b"Storage unit does not match the lottery's bound storage unit";
/// 错误 16：奖品已经被取走，不允许再次提取。
#[error(code = 16)]
const EPrizeAlreadyClaimed: vector<u8> = b"Prize has already been removed from escrow";
/// 错误 17：指定票号对应的票根记录不存在。
#[error(code = 17)]
const ETicketRecordNotFound: vector<u8> = b"Ticket record was not found";
/// 错误 18：当前状态不允许开奖或领奖。
#[error(code = 18)]
const EGameNotDrawableOrClaimable: vector<u8> =
    b"Lottery game is not in a drawable or claimable state";
/// 错误 19：取消时传入的创建者 Character 与创建时记录不一致。
#[error(code = 19)]
const ECreatorCharacterMismatch: vector<u8> = b"Creator character does not match the recorded creator";
/// 错误 20：售罄后不允许取消，必须直接开奖。
#[error(code = 20)]
const ECannotCancelSoldOutGame: vector<u8> = b"Sold out lottery can no longer be canceled";

/// 状态 0：售票中。
const STATE_OPEN: u8 = 0;
/// 状态 1：已开奖，等待中奖者领奖。
const STATE_DRAWN: u8 = 1;
/// 状态 2：奖品已领取，整场游戏已结算完成。
const STATE_SETTLED: u8 = 2;
/// 状态 3：游戏已取消，票款已退回，奖品已退回。
const STATE_CANCELED: u8 = 3;

/// 这个 witness 类型专门用于 StorageUnit 扩展授权。
/// 
/// 只有本模块能构造 `SweepstakesAuth {}`，
/// 因此只有本模块定义的流程才能以“抽奖扩展”的身份调用 SU 扩展接口。
public struct SweepstakesAuth has drop {}

/// 这个结构体保存“一次购买行为”的区间记录。
/// 
/// 用途：
/// - 取消抽奖时逐笔退款。
/// - 保留“谁花了多少钱买了多少张票”的原始支付语义。
/// 
/// 注意：
/// - 它不是单张票根。
/// - 单张票根由后面的 `TicketReceipt` 负责。
public struct TicketPurchase has copy, drop, store {
    /// 购票钱包地址。
    buyer: address,
    /// 购票时使用的 Character ID。
    character_id: ID,
    /// 本次购买拿到的起始票号。
    start_ticket: u64,
    /// 本次购买共买了多少张票。
    ticket_count: u64,
    /// 本次实际支付金额。
    paid_amount: u64,
}

/// 这个结构体表示“单张票”的链上票根。
/// 
/// 每张票都会产生一条独立记录，并通过动态字段挂在 `LotteryGame` 下。
/// 这样：
/// - 前端可以展示当前所有票根哈希和持有人；
/// - 开奖时可以直接用中奖票号 O(1) 读取；
/// - 避免按购买区间线性扫描造成的 gas 路径依赖随机结果。
public struct TicketReceipt has copy, drop, store {
    /// 当前票根持有人地址。
    holder: address,
    /// 当前票根持有人使用的 Character ID。
    character_id: ID,
    /// 这张票的编号。
    ticket_number: u64,
    /// 这张票的哈希票根。
    ticket_hash: vector<u8>,
}

/// 这个结构体保存开奖后的中奖快照。
/// 
/// 一旦开奖，中奖地址、角色、票号、票根哈希都会固化到这里。
public struct WinnerSnapshot has copy, drop, store {
    /// 中奖钱包地址。
    player: address,
    /// 中奖角色 ID。
    character_id: ID,
    /// 命中的票号。
    ticket_number: u64,
    /// 命中的哈希票根。
    ticket_hash: vector<u8>,
}

/// 这是内部辅助结构体，只用于参与 BCS 序列化后做 Blake2b-256 哈希。
/// 
/// 哈希材料包含：
/// - 游戏 ID
/// - 购票地址
/// - 购票角色 ID
/// - 票号
/// 
/// 这样生成出来的票根对于玩家来说是稳定、唯一、可展示的。
public struct TicketHashSeed has copy, drop, store {
    /// 游戏对象 ID。
    game_id: ID,
    /// 购票地址。
    buyer: address,
    /// 购票角色 ID。
    character_id: ID,
    /// 票号。
    ticket_number: u64,
}

/// 这个共享对象表示一场独立的抽奖游戏。
/// 
/// 同一个 StorageUnit 可以同时存在多场抽奖，
/// 因为每一场都会对应一个独立的 `LotteryGame` 共享对象。
public struct LotteryGame has key {
    /// 抽奖对象自己的 UID。
    id: UID,
    /// 本场抽奖绑定到哪个 StorageUnit。
    storage_unit_id: ID,
    /// 创建者钱包地址。
    creator: address,
    /// 创建者 Character ID。
    creator_character_id: ID,
    /// 抽奖标题。
    title: String,
    /// 单张彩票价格，单位是 EVE 最小精度。
    ticket_price: u64,
    /// 总票数。
    total_tickets: u64,
    /// 当前已售票数。
    sold_tickets: u64,
    /// 奖品 type_id。
    prize_type_id: u64,
    /// 奖品数量。
    prize_quantity: u32,
    /// 这里直接托管奖品对象本身。
    /// 
    /// 奖品一旦被提到这里，就不会留在任何玩家可直接操作的库存里，
    /// 只有开奖后的中奖者或取消时的创建者，才能通过本模块定义的流程把它取回。
    prize: Option<Item>,
    /// 这里托管全部售票收入。
    sale_proceeds: Balance<EVE>,
    /// 这里保存按“购买批次”汇总的支付记录，用于取消时逐笔退款。
    purchases: vector<TicketPurchase>,
    /// 这里保存中奖票号；开奖前为空。
    winning_ticket: Option<u64>,
    /// 这里保存中奖快照；开奖前为空。
    winner: Option<WinnerSnapshot>,
    /// 当前游戏状态。
    state: u8,
}

/// 创建抽奖时发出的事件。
public struct GameCreatedEvent has copy, drop {
    /// 新建游戏对象 ID。
    game_id: ID,
    /// 绑定的 StorageUnit ID。
    storage_unit_id: ID,
    /// 创建者地址。
    creator: address,
    /// 创建者 Character ID。
    creator_character_id: ID,
    /// 单张票价。
    ticket_price: u64,
    /// 总票数。
    total_tickets: u64,
    /// 奖品 type_id。
    prize_type_id: u64,
    /// 奖品数量。
    prize_quantity: u32,
}

/// 单张票发行时发出的事件。
/// 
/// 前端可以直接监听这个事件来构建“票根台账”。
public struct TicketIssuedEvent has copy, drop {
    /// 所属游戏 ID。
    game_id: ID,
    /// 票根持有人地址。
    holder: address,
    /// 票根持有人 Character ID。
    character_id: ID,
    /// 票号。
    ticket_number: u64,
    /// 票根哈希。
    ticket_hash: vector<u8>,
}

/// 一次购票批次完成时发出的汇总事件。
public struct TicketsPurchasedEvent has copy, drop {
    /// 游戏 ID。
    game_id: ID,
    /// 购票地址。
    buyer: address,
    /// 购票 Character ID。
    character_id: ID,
    /// 本次批次的起始票号。
    start_ticket: u64,
    /// 本次购买张数。
    ticket_count: u64,
    /// 本次支付总额。
    paid_amount: u64,
    /// 购买后累计已售票数。
    sold_tickets: u64,
}

/// 开奖成功时发出的事件。
public struct WinnerDrawnEvent has copy, drop {
    /// 游戏 ID。
    game_id: ID,
    /// 中奖地址。
    winner: address,
    /// 中奖 Character ID。
    winner_character_id: ID,
    /// 中奖票号。
    winning_ticket: u64,
    /// 中奖彩票对应的哈希票根。
    winning_ticket_hash: vector<u8>,
    /// 开奖时结算给创建者的总票款。
    creator_payout: u64,
}

/// 中奖者领取奖品时发出的事件。
public struct PrizeClaimedEvent has copy, drop {
    /// 游戏 ID。
    game_id: ID,
    /// 领奖地址。
    winner: address,
    /// 领奖 Character ID。
    winner_character_id: ID,
    /// 奖品 type_id。
    prize_type_id: u64,
    /// 奖品数量。
    prize_quantity: u32,
}

/// 游戏取消时发出的事件。
public struct GameCanceledEvent has copy, drop {
    /// 游戏 ID。
    game_id: ID,
    /// 取消者地址，也就是创建者地址。
    creator: address,
    /// 本次总退款金额。
    refunded_amount: u64,
}

/// 创建一场新抽奖，并把奖品从 StorageUnit 提出后锁进抽奖对象。
/// 
/// 返回 `(LotteryGame, OwnerCap<StorageUnit>)`，
/// 是为了方便前端在同一个 PTB 里继续把 `OwnerCap<StorageUnit>` 归还给 Character。
public fun create_game(
    /// 目标 StorageUnit，可变借用，因为要做扩展授权并提取奖品。
    storage_unit_obj: &mut StorageUnit,
    /// 创建者 Character，用于校验 sender，并作为从 SU 提取物品时的角色上下文。
    creator_character: &Character,
    /// 临时借出的 `OwnerCap<StorageUnit>`，用于证明创建者确实拥有这个 SU。
    storage_unit_owner_cap: OwnerCap<StorageUnit>,
    /// 抽奖标题。
    title: String,
    /// 奖品 type_id。
    prize_type_id: u64,
    /// 奖品数量。
    prize_quantity: u32,
    /// 单张票价。
    ticket_price: u64,
    /// 总票数。
    total_tickets: u64,
    /// 交易上下文。
    ctx: &mut TxContext,
): (LotteryGame, OwnerCap<StorageUnit>) {
    /// 总票数必须大于 0。
    assert!(total_tickets > 0, ETotalTicketsMustBePositive);
    /// 单张票价必须大于 0。
    assert!(ticket_price > 0, ETicketPriceMustBePositive);
    /// 奖品数量必须大于 0。
    assert!(prize_quantity > 0, EPrizeQuantityMustBePositive);
    /// 传入的 Character 必须属于当前交易 sender。
    assert_sender_matches_character(creator_character, ctx);

    /// 记录绑定的 StorageUnit 对象 ID。
    let storage_unit_id = object::id(storage_unit_obj);
    /// 校验这份 OwnerCap 的授权目标确实就是当前这个 StorageUnit。
    assert!(
        access::is_authorized(&storage_unit_owner_cap, storage_unit_id),
        EStorageUnitOwnerRequired,
    );

    /// 给这个 SU 授权 `SweepstakesAuth` 扩展身份。
    /// 
    /// 这样抽奖模块就能合法调用：
    /// - `withdraw_item<SweepstakesAuth>`
    /// - `deposit_to_owned<SweepstakesAuth>`
    storage_unit::authorize_extension<SweepstakesAuth>(
        storage_unit_obj,
        &storage_unit_owner_cap,
    );

    /// 把奖品从 SU 中提出来，并立即转入抽奖对象内部托管。
    /// 
    /// 一旦这一步完成，创建者就不能直接把奖品再拿走；
    /// 只有：
    /// - 中奖者在开奖后领奖
    /// - 创建者在未售罄前取消
    /// 这两条受约束的流程可以把奖品移走。
    let prize = storage_unit::withdraw_item<SweepstakesAuth>(
        storage_unit_obj,
        creator_character,
        SweepstakesAuth {},
        prize_type_id,
        prize_quantity,
        ctx,
    );

    /// 记录创建者地址。
    let creator = ctx.sender();
    /// 记录创建者 Character ID。
    let creator_character_id = character::id(creator_character);

    /// 构造新的抽奖共享对象。
    let game = LotteryGame {
        /// 为游戏创建新 UID。
        id: object::new(ctx),
        /// 绑定的 SU ID。
        storage_unit_id,
        /// 创建者地址。
        creator,
        /// 创建者 Character ID。
        creator_character_id,
        /// 抽奖标题。
        title,
        /// 单张票价。
        ticket_price,
        /// 总票数。
        total_tickets,
        /// 新建时已售票数为 0。
        sold_tickets: 0,
        /// 奖品 type_id。
        prize_type_id,
        /// 奖品数量。
        prize_quantity,
        /// 把刚提出来的奖品对象锁进游戏对象。
        prize: option::some(prize),
        /// 初始售票收入为 0。
        sale_proceeds: balance::zero(),
        /// 初始购买批次为空。
        purchases: vector[],
        /// 初始中奖票号为空。
        winning_ticket: option::none(),
        /// 初始中奖快照为空。
        winner: option::none(),
        /// 初始状态为售票中。
        state: STATE_OPEN,
    };

    /// 发出创建事件。
    event::emit(GameCreatedEvent {
        /// 游戏 ID。
        game_id: object::id(&game),
        /// 绑定的 SU ID。
        storage_unit_id,
        /// 创建者地址。
        creator,
        /// 创建者 Character ID。
        creator_character_id,
        /// 单张票价。
        ticket_price,
        /// 总票数。
        total_tickets,
        /// 奖品 type_id。
        prize_type_id,
        /// 奖品数量。
        prize_quantity,
    });

    /// 返回游戏对象和原样返回的 OwnerCap。
    (game, storage_unit_owner_cap)
}

/// 把刚创建好的抽奖对象共享出去，让其他玩家都能参与。
public fun share_game(game: LotteryGame) {
    /// 使用 Sui 共享对象接口把地址拥有对象转成共享对象。
    transfer::share_object(game);
}

/// 购票入口。
/// 
/// 注意：
/// - 每次购买会生成 `ticket_count` 张单独票根。
/// - 每张票根都会写到 `LotteryGame` 的动态字段下。
/// - 每张票根也会发出 `TicketIssuedEvent` 便于前端展示。
public fun buy_tickets(
    /// 抽奖对象，需要可变借用，因为会改写售票数、票款、购买记录和票根台账。
    game: &mut LotteryGame,
    /// 购票玩家 Character。
    buyer_character: &Character,
    /// 支付用的 EVE Coin。
    mut payment: Coin<EVE>,
    /// 本次购买张数。
    ticket_count: u64,
    /// 交易上下文。
    ctx: &mut TxContext,
) {
    /// 只有售票状态下才能购票。
    assert!(game.state == STATE_OPEN, EGameNotOpen);
    /// 购票张数必须大于 0。
    assert!(ticket_count > 0, ETicketCountMustBePositive);
    /// Character 必须属于当前 sender。
    assert_sender_matches_character(buyer_character, ctx);
    /// 购买后不能超过总票数上限。
    assert!(game.sold_tickets + ticket_count <= game.total_tickets, ETicketsSoldOut);

    /// 计算本次应付总价。
    let required_amount = game.ticket_price * ticket_count;
    /// 读取用户实际传入的 Coin 金额。
    let payment_value = coin::value(&payment);
    /// 金额不足则中止。
    assert!(payment_value >= required_amount, EInsufficientPayment);

    /// 记录本批次票号起点。
    let start_ticket = game.sold_tickets;
    /// 记录买家地址。
    let buyer = ctx.sender();
    /// 记录买家 Character ID。
    let buyer_character_id = character::id(buyer_character);

    /// 如果用户支付超额，则先切出找零并退回。
    if (payment_value > required_amount) {
        /// 计算找零金额。
        let change_amount = payment_value - required_amount;
        /// 从支付 Coin 中切出找零部分。
        let change = coin::split(&mut payment, change_amount, ctx);
        /// 把找零退回当前买家。
        transfer::public_transfer(change, buyer);
    };

    /// 把本次实际票款并入抽奖托管余额。
    balance::join(&mut game.sale_proceeds, coin::into_balance(payment));

    /// 为本次购买发行单张票根。
    issue_tickets(game, buyer, buyer_character_id, start_ticket, ticket_count);

    /// 追加一条购买批次记录，供取消时退款使用。
    vector::push_back(
        &mut game.purchases,
        TicketPurchase {
            /// 买家地址。
            buyer,
            /// 买家 Character ID。
            character_id: buyer_character_id,
            /// 本批次起始票号。
            start_ticket,
            /// 本批次张数。
            ticket_count,
            /// 本批次实际支付金额。
            paid_amount: required_amount,
        },
    );

    /// 更新累计已售票数。
    game.sold_tickets = game.sold_tickets + ticket_count;

    /// 发出本次购票汇总事件。
    event::emit(TicketsPurchasedEvent {
        /// 游戏 ID。
        game_id: object::id(game),
        /// 买家地址。
        buyer,
        /// 买家 Character ID。
        character_id: buyer_character_id,
        /// 起始票号。
        start_ticket,
        /// 购买张数。
        ticket_count,
        /// 本次支付总额。
        paid_amount: required_amount,
        /// 购买后累计已售票数。
        sold_tickets: game.sold_tickets,
    });
}

/// 开奖入口。
/// 
/// 这里故意写成“非 public 的 entry fun”，
/// 这是 Sui 官方随机数文档建议的写法之一。
/// 
/// 这一版实现的重要改进：
/// - 旧逻辑需要按购买区间线性扫描定位中奖者；
/// - 新逻辑直接用 `winning_ticket` 到动态字段里取 `TicketReceipt`；
/// - 因此开奖路径不再依赖“随机数落在哪个购买区间”，gas 路径更稳定。
entry fun draw_winner(game: &mut LotteryGame, randomness: &Random, ctx: &mut TxContext) {
    /// 必须仍然处于售票状态。
    assert!(game.state == STATE_OPEN, EGameNotOpen);
    /// 必须已经售罄。
    assert!(game.sold_tickets == game.total_tickets, ENotSoldOut);
    /// 不能重复开奖。
    assert!(option::is_none(&game.winner), EWinnerAlreadyDrawn);

    /// 基于链上 `Random` 创建随机数生成器。
    let mut generator = random::new_generator(randomness, ctx);
    /// 在 `[0, total_tickets - 1]` 区间内生成一个中奖彩票编号。
    let winning_ticket =
        random::generate_u64_in_range(&mut generator, 0, game.total_tickets - 1);
    /// 直接按票号读取单张票根记录。
    let ticket = ticket_receipt_internal(game, winning_ticket);
    /// 组装中奖快照。
    let winner = WinnerSnapshot {
        /// 中奖地址取自票根持有人。
        player: ticket.holder,
        /// 中奖角色 ID 取自票根。
        character_id: ticket.character_id,
        /// 中奖票号。
        ticket_number: ticket.ticket_number,
        /// 中奖哈希票根。
        ticket_hash: ticket.ticket_hash,
    };
    /// 在结算给创建者之前，先把金额记下来供事件输出。
    let creator_payout = balance::value(&game.sale_proceeds);

    /// 写入中奖票号。
    game.winning_ticket = option::some(winning_ticket);
    /// 写入中奖快照。
    game.winner = option::some(winner);
    /// 切换到“已开奖待领奖”状态。
    game.state = STATE_DRAWN;

    /// 把全部售票收入一次性结算给创建者。
    pay_creator(game, ctx);

    /// 发出开奖事件。
    event::emit(WinnerDrawnEvent {
        /// 游戏 ID。
        game_id: object::id(game),
        /// 中奖地址。
        winner: ticket.holder,
        /// 中奖 Character ID。
        winner_character_id: ticket.character_id,
        /// 中奖票号。
        winning_ticket,
        /// 中奖彩票哈希。
        winning_ticket_hash: ticket.ticket_hash,
        /// 给创建者的总票款。
        creator_payout,
    });
}

/// 领奖入口。
public fun claim_prize(
    /// 抽奖对象，需要可变借用，因为领奖后要把奖品移走并更新状态。
    game: &mut LotteryGame,
    /// 绑定的 StorageUnit，需要可变借用，因为奖品会被存回中奖角色的 owned inventory。
    storage_unit_obj: &mut StorageUnit,
    /// 中奖者用于领奖的 Character。
    winner_character: &Character,
    /// 交易上下文。
    ctx: &mut TxContext,
) {
    /// 只有已开奖待领奖状态才允许领奖。
    assert!(game.state == STATE_DRAWN, EGameNotDrawableOrClaimable);
    /// 必须使用这场游戏绑定的那个 StorageUnit。
    assert_storage_unit_matches(game, storage_unit_obj);
    /// Character 必须属于当前 sender。
    assert_sender_matches_character(winner_character, ctx);

    /// 读取中奖快照。
    let winner = winner_snapshot(game);
    /// sender 必须等于开奖时记录的中奖地址。
    assert!(ctx.sender() == winner.player, EOnlyWinnerCanClaim);
    /// 传入的 Character ID 必须等于中奖快照里的角色 ID。
    assert!(
        character::id(winner_character) == winner.character_id,
        EWinnerCharacterMismatch,
    );

    /// 从抽奖对象里提取奖品。
    let prize = take_prize(game);

    /// 把奖品存回中奖角色在该 StorageUnit 下的 owned inventory。
    /// 
    /// 这里给的是“奖品所有权”，不是“整个 StorageUnit 的控制权”。
    storage_unit::deposit_to_owned<SweepstakesAuth>(
        storage_unit_obj,
        winner_character,
        prize,
        SweepstakesAuth {},
        ctx,
    );

    /// 状态改为已结算。
    game.state = STATE_SETTLED;

    /// 发出领奖事件。
    event::emit(PrizeClaimedEvent {
        /// 游戏 ID。
        game_id: object::id(game),
        /// 领奖地址。
        winner: winner.player,
        /// 领奖角色 ID。
        winner_character_id: winner.character_id,
        /// 奖品 type_id。
        prize_type_id: game.prize_type_id,
        /// 奖品数量。
        prize_quantity: game.prize_quantity,
    });
}

/// 取消抽奖入口。
public fun cancel_game(
    /// 抽奖对象，需要可变借用，因为要退款、返还奖品并更新状态。
    game: &mut LotteryGame,
    /// 绑定的 StorageUnit，需要可变借用，因为奖品要退回创建者在该 SU 下的 owned inventory。
    storage_unit_obj: &mut StorageUnit,
    /// 创建者 Character。
    creator_character: &Character,
    /// 交易上下文。
    ctx: &mut TxContext,
) {
    /// 只有售票状态下才能取消。
    assert!(game.state == STATE_OPEN, EGameNotOpen);
    /// 售罄后不允许取消，只能开奖。
    assert!(game.sold_tickets < game.total_tickets, ECannotCancelSoldOutGame);
    /// sender 必须是创建者地址。
    assert!(ctx.sender() == game.creator, EOnlyCreatorCanCancel);
    /// Character 必须属于当前 sender。
    assert_sender_matches_character(creator_character, ctx);
    /// 传入 Character ID 必须等于创建时记录的创建者角色 ID。
    assert!(
        character::id(creator_character) == game.creator_character_id,
        ECreatorCharacterMismatch,
    );
    /// 传入 SU 必须等于绑定的 SU。
    assert_storage_unit_matches(game, storage_unit_obj);

    /// 先逐笔退回全部票款。
    let refunded_amount = refund_all_buyers(game, ctx);
    /// 再把锁住的奖品提出来。
    let prize = take_prize(game);

    /// 把奖品退回创建者在该 SU 下的 owned inventory。
    storage_unit::deposit_to_owned<SweepstakesAuth>(
        storage_unit_obj,
        creator_character,
        prize,
        SweepstakesAuth {},
        ctx,
    );

    /// 切换到取消状态。
    game.state = STATE_CANCELED;

    /// 发出取消事件。
    event::emit(GameCanceledEvent {
        /// 游戏 ID。
        game_id: object::id(game),
        /// 创建者地址。
        creator: game.creator,
        /// 总退款金额。
        refunded_amount,
    });
}

/// 返回标题。
public fun title(game: &LotteryGame): &String {
    /// 直接返回标题引用。
    &game.title
}

/// 返回绑定的 StorageUnit ID。
public fun storage_unit_id(game: &LotteryGame): ID {
    /// 直接返回绑定的 SU ID。
    game.storage_unit_id
}

/// 返回创建者地址。
public fun creator(game: &LotteryGame): address {
    /// 直接返回创建者地址。
    game.creator
}

/// 返回创建者 Character ID。
public fun creator_character_id(game: &LotteryGame): ID {
    /// 直接返回创建者 Character ID。
    game.creator_character_id
}

/// 返回当前游戏状态。
public fun state(game: &LotteryGame): u8 {
    /// 直接返回状态值。
    game.state
}

/// 返回单张票价。
public fun ticket_price(game: &LotteryGame): u64 {
    /// 直接返回票价。
    game.ticket_price
}

/// 返回总票数。
public fun total_tickets(game: &LotteryGame): u64 {
    /// 直接返回总票数。
    game.total_tickets
}

/// 返回已售票数。
public fun sold_tickets(game: &LotteryGame): u64 {
    /// 直接返回已售票数。
    game.sold_tickets
}

/// 返回奖品 type_id。
public fun prize_type_id(game: &LotteryGame): u64 {
    /// 直接返回奖品 type_id。
    game.prize_type_id
}

/// 返回奖品数量。
public fun prize_quantity(game: &LotteryGame): u32 {
    /// 直接返回奖品数量。
    game.prize_quantity
}

/// 返回奖品当前是否仍然锁在抽奖对象里。
public fun prize_locked(game: &LotteryGame): bool {
    /// 只要 `game.prize` 里还有对象，就说明奖品仍处于锁定状态。
    option::is_some(&game.prize)
}

/// 返回当前托管的票款金额。
public fun sale_proceeds_value(game: &LotteryGame): u64 {
    /// 直接读取 `Balance<EVE>` 数值。
    balance::value(&game.sale_proceeds)
}

/// 返回中奖票号的 `Option` 引用。
public fun winning_ticket(game: &LotteryGame): &Option<u64> {
    /// 直接返回中奖票号字段引用。
    &game.winning_ticket
}

/// 返回中奖快照的 `Option` 引用。
public fun winner(game: &LotteryGame): &Option<WinnerSnapshot> {
    /// 直接返回中奖快照字段引用。
    &game.winner
}

/// 返回购买批次记录数组的引用。
public fun purchases(game: &LotteryGame): &vector<TicketPurchase> {
    /// 直接返回购买批次数组引用。
    &game.purchases
}

/// 返回某一张票的票根记录。
/// 
/// 前端实际更适合通过 RPC 读取动态字段；
/// 这里提供的是链上读取接口，方便其他 Move 模块使用。
public fun ticket_receipt(game: &LotteryGame, ticket_number: u64): TicketReceipt {
    /// 复用内部读取函数返回票根副本。
    ticket_receipt_internal(game, ticket_number)
}

/// 内部辅助函数：校验传入的 Character 是否属于当前 sender。
fun assert_sender_matches_character(character_obj: &Character, ctx: &TxContext) {
    /// 比较角色地址和交易发送者地址，不一致就中止。
    assert!(
        character::character_address(character_obj) == ctx.sender(),
        ECharacterSenderMismatch,
    );
}

/// 内部辅助函数：校验传入的 StorageUnit 是否与游戏绑定的 SU 一致。
fun assert_storage_unit_matches(game: &LotteryGame, storage_unit_obj: &StorageUnit) {
    /// 直接比对对象 ID。
    assert!(game.storage_unit_id == object::id(storage_unit_obj), EStorageUnitMismatch);
}

/// 内部辅助函数：读取某张票对应的票根记录。
fun ticket_receipt_internal(game: &LotteryGame, ticket_number: u64): TicketReceipt {
    /// 票号必须小于当前已售票数。
    assert!(ticket_number < game.sold_tickets, ETicketRecordNotFound);
    /// 对应的动态字段必须确实存在。
    assert!(df::exists_(&game.id, ticket_number), ETicketRecordNotFound);
    /// 从动态字段中读取并返回票根记录副本。
    *df::borrow<u64, TicketReceipt>(&game.id, ticket_number)
}

/// 内部辅助函数：读取中奖快照。
fun winner_snapshot(game: &LotteryGame): WinnerSnapshot {
    /// 要求中奖快照已经存在。
    assert!(option::is_some(&game.winner), EWinnerNotDrawn);
    /// 返回中奖快照副本。
    *option::borrow(&game.winner)
}

/// 内部辅助函数：从抽奖对象里提取奖品。
fun take_prize(game: &mut LotteryGame): Item {
    /// 奖品必须仍然存在。
    assert!(option::is_some(&game.prize), EPrizeAlreadyClaimed);
    /// 从 `Option<Item>` 中取出并返回。
    option::extract(&mut game.prize)
}

/// 内部辅助函数：给本次购票批次发行单张票根。
fun issue_tickets(
    /// 游戏对象，需要可变借用，因为要写动态字段。
    game: &mut LotteryGame,
    /// 买家地址。
    buyer: address,
    /// 买家 Character ID。
    buyer_character_id: ID,
    /// 本批次的起始票号。
    start_ticket: u64,
    /// 本批次购买张数。
    ticket_count: u64,
) {
    /// 先取一次游戏 ID，后面循环复用。
    let game_id = object::id(game);
    /// 循环偏移量从 0 开始。
    let mut offset = 0;
    /// 逐张发行票根。
    while (offset < ticket_count) {
        /// 当前票号 = 起始票号 + 偏移量。
        let ticket_number = start_ticket + offset;
        /// 计算当前票的哈希票根。
        let ticket_hash = compute_ticket_hash(
            game_id,
            buyer,
            buyer_character_id,
            ticket_number,
        );
        /// 组装单张票根记录。
        let receipt = TicketReceipt {
            /// 当前持有人地址。
            holder: buyer,
            /// 当前持有人 Character ID。
            character_id: buyer_character_id,
            /// 当前票号。
            ticket_number,
            /// 当前票根哈希。
            ticket_hash,
        };
        /// 把票根记录挂到游戏对象的动态字段下，字段名就是票号。
        df::add(&mut game.id, ticket_number, receipt);

        /// 同时发出“单张票已发行”事件，方便前端建立票根台账。
        event::emit(TicketIssuedEvent {
            /// 游戏 ID。
            game_id,
            /// 持有人地址。
            holder: buyer,
            /// 持有人 Character ID。
            character_id: buyer_character_id,
            /// 票号。
            ticket_number,
            /// 票根哈希。
            ticket_hash,
        });
        /// 继续发行下一张票。
        offset = offset + 1;
    };
}

/// 内部辅助函数：计算单张票的哈希票根。
fun compute_ticket_hash(
    /// 游戏 ID。
    game_id: ID,
    /// 买家地址。
    buyer: address,
    /// 买家 Character ID。
    buyer_character_id: ID,
    /// 票号。
    ticket_number: u64,
): vector<u8> {
    /// 先把所有参与哈希的材料组装成结构体。
    let seed = TicketHashSeed {
        /// 游戏 ID。
        game_id,
        /// 买家地址。
        buyer,
        /// 买家 Character ID。
        character_id: buyer_character_id,
        /// 票号。
        ticket_number,
    };
    /// 对 BCS 序列化后的字节做 Blake2b-256，得到 32 字节票根哈希。
    hash::blake2b256(&bcs::to_bytes(&seed))
}

/// 内部辅助函数：把全部票款结算给创建者。
fun pay_creator(game: &mut LotteryGame, ctx: &mut TxContext) {
    /// 读取当前票款总额。
    let proceeds = balance::value(&game.sale_proceeds);
    /// 只有金额大于 0 时才需要真的转账。
    if (proceeds > 0) {
        /// 从 `Balance<EVE>` 中提走全部余额。
        let proceeds_balance = balance::withdraw_all(&mut game.sale_proceeds);
        /// 把余额转回可转账的 `Coin<EVE>`。
        let proceeds_coin = coin::from_balance(proceeds_balance, ctx);
        /// 把票款转给创建者地址。
        transfer::public_transfer(proceeds_coin, game.creator);
    };
}

/// 内部辅助函数：逐笔给所有购票人退款，并返回退款总额。
fun refund_all_buyers(game: &mut LotteryGame, ctx: &mut TxContext): u64 {
    /// 在退款前先记录总金额，作为返回值。
    let refunded_total = balance::value(&game.sale_proceeds);
    /// 读取购买批次数量。
    let len = game.purchases.length();
    /// 从第 0 条开始遍历。
    let mut index = 0;

    /// 逐条扫描购买批次记录。
    while (index < len) {
        /// 取出当前购买批次副本。
        let purchase = *vector::borrow(&game.purchases, index);
        /// 只有支付金额大于 0 时才需要退款。
        if (purchase.paid_amount > 0) {
            /// 从票款池中切出该批次应退金额。
            let refund_balance = balance::split(&mut game.sale_proceeds, purchase.paid_amount);
            /// 转成 `Coin<EVE>`。
            let refund_coin = coin::from_balance(refund_balance, ctx);
            /// 原路退回给该批次买家地址。
            transfer::public_transfer(refund_coin, purchase.buyer);
        };
        /// 继续处理下一条购买批次。
        index = index + 1;
    };

    /// 返回本次总退款额。
    refunded_total
}
