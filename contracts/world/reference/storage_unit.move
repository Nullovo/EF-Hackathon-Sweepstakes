/// 这是 `world/sources/assemblies/storage_unit.move` 的中文阅读注释版。
/// 说明：
/// 1. 这份文件用于阅读和审计逻辑，不参与编译。
/// 2. 我尽量按“结构体字段 / 事件 / 主要函数 / 权限检查 / 物品流转路径”补充详细中文解释。
/// 3. 原始 `world` 合约逻辑没有被改动，真正参与构建的仍然是 `sources/assemblies/storage_unit.move`。
///
/// This module handles the functionality of the in-game Storage Unit Assembly
///
/// The Storage Unit is a programmable, on-chain storage structure.
/// It can allow players to store, withdraw, and manage items under rules they design themselves.
/// The behaviour of a Storage Unit can be customized by registering a custom contract
/// using the typed witness pattern. https://github.com/evefrontier/world-contracts/blob/main/docs/architechture.md#layer-3-player-extensions-moddability
///
/// Storage Units support three access modes to enable player-to-player interactions:
///
/// 1. **Extension-based access** (Main inventory):
///    - Functions: `deposit_item<Auth>`, `withdraw_item<Auth>`
///    - Allows 3rd party contracts to handle inventory operations on behalf of the owner
///
/// 2. **Extension-to-owned deposit**:
///    - Function: `deposit_to_owned<Auth>`
///    - Allows extensions to push items into a player's owned inventory
///    - Target is validated as an existing Character (owner_cap_id derived on-chain)
///    - Target player does NOT need to be the transaction sender
///    - Source inventory depends on extension logic (main or owned)
///    - Enables async trading, guild hangars, automated rewards
///
/// 3. **Owner-direct access** (Owned inventory)
///    - Functions: `deposit_by_owner`, `withdraw_by_owner`
///    - Allows the owner to deposit/withdraw from their owned inventory
///    - Requires OwnerCap + sender == character address
///
/// Future pattern: Storage Units (extension-controlled), Ships (owner-controlled)
module world::storage_unit;

use std::{string::String, type_name::{Self, TypeName}};
use sui::{clock::Clock, derived_object, dynamic_field as df, event};
use world::{
    access::{Self, OwnerCap, ServerAddressRegistry, AdminACL},
    character::Character,
    energy::EnergyConfig,
    in_game_id::{Self, TenantItemId},
    inventory::{Self, Inventory, Item},
    location::{Self, Location, LocationRegistry},
    metadata::{Self, Metadata},
    network_node::{NetworkNode, OfflineAssemblies, HandleOrphanedAssemblies, UpdateEnergySources},
    object_registry::ObjectRegistry,
    status::{Self, AssemblyStatus, Status}
};

// === Errors ===
#[error(code = 0)]
const EStorageUnitTypeIdEmpty: vector<u8> = b"StorageUnit TypeId is empty";
#[error(code = 1)]
const EStorageUnitItemIdEmpty: vector<u8> = b"StorageUnit ItemId is empty";
#[error(code = 2)]
const EStorageUnitAlreadyExists: vector<u8> = b"StorageUnit with the same Item Id already exists";
#[error(code = 3)]
const EAssemblyNotAuthorized: vector<u8> = b"StorageUnit access not authorized";
#[error(code = 4)]
const EExtensionNotAuthorized: vector<u8> =
    b"Access only authorized for the custom contract of the registered type";
#[error(code = 5)]
const EInventoryNotAuthorized: vector<u8> = b"Inventory Access not authorized";
#[error(code = 6)]
const ENotOnline: vector<u8> = b"Storage Unit is not online";
#[error(code = 7)]
const ETenantMismatch: vector<u8> = b"Item cannot be transferred across tenants";
#[error(code = 8)]
const ENetworkNodeMismatch: vector<u8> =
    b"Provided network node does not match the storage unit's configured energy source";
#[error(code = 9)]
const EStorageUnitInvalidState: vector<u8> = b"Storage Unit should be offline";
#[error(code = 10)]
const ESenderCannotAccessCharacter: vector<u8> = b"Address cannot access Character";
#[error(code = 11)]
const EItemParentMismatch: vector<u8> = b"Item was not withdrawn from this storage unit";
#[error(code = 12)]
const EMetadataNotSet: vector<u8> = b"Metadata not set on assembly";

// Future thought: Can we make the behaviour attached dynamically using dof
// === Structs ===
// 中文说明：
// `StorageUnit` 是一个链上 object。
// 它自己不直接把每个物品都存成独立 object，而是把若干 `Inventory`
// 作为 dynamic field 挂在自己下面，再由 `Inventory` 记录各类物品数量。
// 所以理解这个模块时，要把它想成：
// “一个 SU object + 多个按 owner_cap_id 分区的库存 + 少量扩展授权状态”。
public struct StorageUnit has key {
    // SU 自身的 UID，全链唯一对象标识。
    id: UID,
    // 游戏内业务键，通常是 tenant + item_id 的组合。
    key: TenantItemId,
    // SU 自己的 OwnerCap 对象 ID。
    // 这一份 owner_cap_id 对应的是 SU 主库存。
    owner_cap_id: ID,
    // SU 的类型 ID。
    type_id: u64,
    // 当前在线/离线等生命周期状态。
    status: AssemblyStatus,
    // SU 的位置数据。
    location: Location,
    // 当前这个 SU 下已创建过的库存 key 列表。
    // 其中既可能包含 SU 主库存的 key，也可能包含若干 Character 的 owner_cap_id。
    inventory_keys: vector<ID>,
    // 绑定的能源节点 ID，可选。
    energy_source_id: Option<ID>,
    // 可选元数据，例如名称、描述、URL。
    metadata: Option<Metadata>,
    // 当前登记的扩展类型。
    // 例如注册了 `swap::SwapAuth` 后，这里会记录对应的 TypeName。
    // 之后扩展才能通过 `deposit_item<Auth>` / `withdraw_item<Auth>` 操作 SU 主库存。
    extension: Option<TypeName>,
}

// === Events ===
public struct StorageUnitCreatedEvent has copy, drop {
    // 新建 SU 的对象 ID。
    storage_unit_id: ID,
    // 业务键。
    assembly_key: TenantItemId,
    // SU 自己的 owner_cap_id，也就是 SU 主库存对应的库存 key。
    owner_cap_id: ID,
    // SU 类型 ID。
    type_id: u64,
    // 主库存最大容量。
    max_capacity: u64,
    // 位置哈希。
    location_hash: vector<u8>,
    // 初始状态。
    status: Status,
}

public struct ExtensionAuthorizedEvent has copy, drop {
    // 被授权的 SU ID。
    assembly_id: ID,
    // SU 业务键。
    assembly_key: TenantItemId,
    // 新授权的扩展类型。
    extension_type: TypeName,
    // 之前已经绑定的扩展类型。
    previous_extension: Option<TypeName>,
    // 用来完成授权校验的 OwnerCap<StorageUnit> 的对象 ID。
    owner_cap_id: ID,
}

// === Public Functions ===
// 中文说明：
// 这是“注册扩展”的核心入口。
// 一旦把某个 witness 类型写进 `storage_unit.extension`，
// 对应模块后续就可以凭 `Auth` 类型安全地操作 SU 主库存。
public fun authorize_extension<Auth: drop>(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    // 先取当前 SU 的对象 ID。
    let storage_unit_id = object::id(storage_unit);
    // 校验传入的 OwnerCap<StorageUnit> 确实授权到这个 SU。
    assert!(access::is_authorized(owner_cap, storage_unit_id), EAssemblyNotAuthorized);
    // 记录旧扩展，便于事件里回看本次是否是替换。
    let previous_extension = storage_unit.extension;
    // 写入新的扩展类型标识。
    storage_unit.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
    // 发出扩展授权事件。
    event::emit(ExtensionAuthorizedEvent {
        assembly_id: storage_unit_id,
        assembly_key: storage_unit.key,
        extension_type: type_name::with_defining_ids<Auth>(),
        previous_extension,
        owner_cap_id: object::id(owner_cap),
    });
}

public fun online(
    storage_unit: &mut StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    // 上线操作只能由 SU owner 发起。
    let storage_unit_id = object::id(storage_unit);
    assert!(access::is_authorized(owner_cap, storage_unit_id), EAssemblyNotAuthorized);
    // SU 必须已经绑定能源节点。
    assert!(option::is_some(&storage_unit.energy_source_id), ENetworkNodeMismatch);
    // 传入的能源节点必须和 SU 记录的那个节点一致。
    assert!(
        *option::borrow(&storage_unit.energy_source_id) == object::id(network_node),
        ENetworkNodeMismatch,
    );
    // 预留能量。
    reserve_energy(storage_unit, network_node, energy_config);

    // 修改状态为 online。
    storage_unit.status.online(storage_unit_id, storage_unit.key);
}

public fun offline(
    storage_unit: &mut StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    let storage_unit_id = object::id(storage_unit);
    assert!(access::is_authorized(owner_cap, storage_unit_id), EAssemblyNotAuthorized);

    // Verify network node matches the storage unit's energy source
    // 中文说明：下线时也必须确认传入的是同一个能源节点，避免错放/错扣能量。
    assert!(option::is_some(&storage_unit.energy_source_id), ENetworkNodeMismatch);
    assert!(
        *option::borrow(&storage_unit.energy_source_id) == object::id(network_node),
        ENetworkNodeMismatch,
    );
    // 释放能量占用。
    release_energy(storage_unit, network_node, energy_config);

    // 修改状态为 offline。
    storage_unit.status.offline(storage_unit_id, storage_unit.key);
}

// TODO: add additional check for proximity proof
/// Bridges items from chain to game inventory
// 中文说明：
// 这是“链上物品回收 / 烧毁并返还到游戏侧”的入口。
// 它并不是简单转账，而是从某个库存里扣掉数量，并要求提供位置证明。
public fun chain_item_to_game_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    quantity: u32,
    location_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 只有角色本人地址才能操作自己的 Character。
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    // 拿到当前 SU 的对象 ID。
    let storage_unit_id = object::id(storage_unit);
    // 校验 owner_cap 是否有权操作该 Character 对应库存，或该 SU 自身库存。
    check_inventory_authorization(owner_cap, storage_unit, character.id());
    // 只有在线 SU 才允许进行物品桥接。
    assert!(storage_unit.status.is_online(), ENotOnline);

    // owner_cap_id 决定本次要操作的是哪一份库存。
    let owner_cap_id = object::id(owner_cap);
    // 借出对应库存并执行 burn。
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.burn_items_with_proof(
        storage_unit_id,
        storage_unit.key,
        character,
        server_registry,
        &storage_unit.location,
        location_proof,
        type_id,
        quantity,
        clock,
        ctx,
    );
}

// 中文说明：
// 这是扩展向 SU 主库存“存货”的入口。
// 注意：这里不是存到某个玩家个人库存，而是存到 `storage_unit.owner_cap_id` 对应的主库存。
public fun deposit_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    item: Item,
    _: Auth,
    _: &mut TxContext,
) {
    // 当前 SU 的 ID，后面会拿来做 parent_id 校验。
    let storage_unit_id = object::id(storage_unit);
    // 必须已经注册了对应的扩展 witness。
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    // 只有在线 SU 才能存货。
    assert!(storage_unit.status.is_online(), ENotOnline);
    // 物品租户必须和 SU 属于同一个 tenant。
    assert!(inventory::tenant(&item) == storage_unit.key.tenant(), ETenantMismatch);
    // 这个 Item 必须确实来自当前 SU，不能把别的 SU 提出来的 Item 塞进来。
    assert!(inventory::parent_id(&item) == storage_unit_id, EItemParentMismatch);
    // 这里借出的就是 SU 主库存。
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        storage_unit.owner_cap_id,
    );
    inventory.deposit_item(
        storage_unit_id,
        storage_unit.key,
        character,
        item,
    );
}

// 中文说明：
// 这是扩展从 SU 主库存“提货”的入口。
// 对应 swap 里给玩家发货、lottery 里锁奖品/发奖，走的都是这类逻辑。
public fun withdraw_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    _: Auth,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): Item {
    // 当前 SU 的对象 ID，同时也是生成 transit Item 时的 parent_id。
    let storage_unit_id = object::id(storage_unit);
    // 只有当前已注册扩展，才允许代表 SU 主库存提货。
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    // 只有在线 SU 才能提货。
    assert!(storage_unit.status.is_online(), ENotOnline);

    // 这里借出的也是 SU 主库存。
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        storage_unit.owner_cap_id,
    );

    inventory.withdraw_item(
        storage_unit_id,
        storage_unit.key,
        character,
        type_id,
        quantity,
        storage_unit.location.hash(),
        ctx,
    )
}

/// Extension-authorized deposit into a player's owned inventory.
/// Unlike `deposit_by_owner`, the recipient (the `character` argument) does NOT need to be
/// the transaction sender. The recipient's owned inventory is derived from
/// `character.owner_cap_id()`, ensuring the character is a valid, existing Character.
/// Creates the owned inventory if it doesn't exist yet.
// 中文说明：
// 这是扩展把物品“发给某个角色”的入口。
// 与 `deposit_item<Auth>` 最大区别在于：
// - `deposit_item<Auth>` 存入 SU 主库存
// - `deposit_to_owned<Auth>` 存入某个 Character 的个人库存
// 所以 swap 给玩家发货，最终就是把输出物品存到了玩家角色自己的库存里。
public fun deposit_to_owned<Auth: drop>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    item: Item,
    _: Auth,
    _: &mut TxContext,
) {
    // 当前 SU 的对象 ID，用于校验 Item 的来源。
    let storage_unit_id = object::id(storage_unit);
    // 必须先注册扩展。
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    // 只有在线 SU 才能派发。
    assert!(storage_unit.status.is_online(), ENotOnline);
    // 物品 tenant 和角色 tenant 都必须匹配当前 SU。
    assert!(item.tenant() == storage_unit.key.tenant(), ETenantMismatch);
    assert!(character.tenant() == storage_unit.key.tenant(), ETenantMismatch);
    // 物品必须来自当前 SU。
    assert!(item.parent_id() == storage_unit_id, EItemParentMismatch);

    // 这里取的不是 SU 主 owner_cap_id，而是目标 Character 自己的 owner_cap_id。
    let owner_cap_id = character.owner_cap_id();

    // 如果这个 Character 在当前 SU 下还没有个人库存，就自动创建一份。
    if (!df::exists_(&storage_unit.id, owner_cap_id)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        // 个人库存容量继承主库存上限。
        let owned_inventory = inventory::create(owner_inv.max_capacity());
        storage_unit.inventory_keys.push_back(owner_cap_id);
        df::add(&mut storage_unit.id, owner_cap_id, owned_inventory);
    };

    // 把物品记入角色个人库存。
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.deposit_item(
        storage_unit_id,
        storage_unit.key,
        character,
        item,
    );
}

// 中文说明：
// 这是 owner 直接把中转 Item 存回“自己有权限的那份库存”的入口。
// 这里的权限不是扩展权限，而是 OwnerCap 权限。
public fun deposit_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    item: Item,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    ctx: &mut TxContext,
) {
    // 角色地址必须就是交易发送者。
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    // 当前 SU ID。
    let storage_unit_id = object::id(storage_unit);
    // 当前 owner_cap 对应哪一份库存，完全由它自己的 object id 决定。
    let owner_cap_id = object::id(owner_cap);
    // SU 必须在线。
    assert!(storage_unit.status.is_online(), ENotOnline);
    // 校验这个 owner_cap 是否有权访问这份库存。
    check_inventory_authorization(owner_cap, storage_unit, character.id());
    // 物品 tenant / 来源 SU 都必须匹配。
    assert!(inventory::tenant(&item) == storage_unit.key.tenant(), ETenantMismatch);
    assert!(inventory::parent_id(&item) == storage_unit_id, EItemParentMismatch);

    // 存入 owner_cap 对应的库存，而不是固定存入主库存。
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );

    inventory.deposit_item(
        storage_unit_id,
        storage_unit.key,
        character,
        item,
    );
}

// 中文说明：
// 这是 owner 直接从“自己有权限的那份库存”里提货的入口。
// 如果传的是 `OwnerCap<Character>`，提的是角色个人库存。
// 如果传的是 `OwnerCap<StorageUnit>`，提的是 SU 主库存。
public fun withdraw_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): Item {
    // 必须是角色本人发交易。
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    // 当前 SU ID，会写入新生成的 transit Item.parent_id。
    let storage_unit_id = object::id(storage_unit);
    // 当前 owner_cap 对应的库存 key。
    let owner_cap_id = object::id(owner_cap);
    // SU 必须在线。
    assert!(storage_unit.status.is_online(), ENotOnline);
    // 校验 owner_cap 权限。
    check_inventory_authorization(owner_cap, storage_unit, character.id());

    // 读取并操作 owner_cap 对应的那份库存。
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );

    inventory.withdraw_item(
        storage_unit_id,
        storage_unit.key,
        character,
        type_id,
        quantity,
        storage_unit.location.hash(),
        ctx,
    )
}

public fun update_metadata_name(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
    name: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    assert!(option::is_some(&storage_unit.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut storage_unit.metadata);
    metadata.update_name(storage_unit.key, name);
}

public fun update_metadata_description(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
    description: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    assert!(option::is_some(&storage_unit.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut storage_unit.metadata);
    metadata.update_description(storage_unit.key, description);
}

public fun update_metadata_url(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
    url: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    assert!(option::is_some(&storage_unit.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut storage_unit.metadata);
    metadata.update_url(storage_unit.key, url);
}

/// Reveals plain-text location (solarsystem, x, y, z) for this storage unit. Admin ACL only. Optional; enables dapps (e.g. route maps).
/// Temporary: use until the offchain location reveal service is ready.
public fun reveal_location(
    storage_unit: &StorageUnit,
    registry: &mut LocationRegistry,
    admin_acl: &AdminACL,
    solarsystem: u64,
    x: String,
    y: String,
    z: String,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    location::reveal_location(
        registry,
        object::id(storage_unit),
        storage_unit.key,
        storage_unit.type_id,
        storage_unit.owner_cap_id,
        location::hash(&storage_unit.location),
        solarsystem,
        x,
        y,
        z,
    );
}

// === View Functions ===
public fun status(storage_unit: &StorageUnit): &AssemblyStatus {
    &storage_unit.status
}

public fun location(storage_unit: &StorageUnit): &Location {
    &storage_unit.location
}

public fun inventory(storage_unit: &StorageUnit, owner_cap_id: ID): &Inventory {
    df::borrow(&storage_unit.id, owner_cap_id)
}

public fun owner_cap_id(storage_unit: &StorageUnit): ID {
    storage_unit.owner_cap_id
}

/// Returns the storage unit's energy source (network node) ID if set
public fun energy_source_id(storage_unit: &StorageUnit): &Option<ID> {
    &storage_unit.energy_source_id
}

// === Admin Functions ===
// 中文说明：
// `anchor` 可以理解为“把游戏内的一个 Storage Unit 实例正式锚定到链上”。
// 它会：
// 1. 生成 SU object
// 2. 创建 OwnerCap<StorageUnit>
// 3. 初始化主库存
// 4. 绑定网络节点和元数据
// 5. 把 OwnerCap 转给目标 Character
public fun anchor(
    registry: &mut ObjectRegistry,
    network_node: &mut NetworkNode,
    character: &Character,
    admin_acl: &AdminACL,
    item_id: u64,
    type_id: u64,
    max_capacity: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): StorageUnit {
    // type_id 和 item_id 都必须存在。
    assert!(type_id != 0, EStorageUnitTypeIdEmpty);
    assert!(item_id != 0, EStorageUnitItemIdEmpty);

    // 根据 item_id + tenant 生成业务唯一键。
    let storage_unit_key = in_game_id::create_key(item_id, character.tenant());
    // 同一个键不能重复创建。
    assert!(!registry.object_exists(storage_unit_key), EStorageUnitAlreadyExists);

    // 在 object registry 下派生出这个 SU 的 UID。
    let assembly_uid = derived_object::claim(registry.borrow_registry_id(), storage_unit_key);
    let assembly_id = object::uid_to_inner(&assembly_uid);
    let network_node_id = object::id(network_node);

    // Create owner cap and transfer to Character object
    // 为这个 SU 创建一份 OwnerCap<StorageUnit>。
    let owner_cap = access::create_owner_cap_by_id<StorageUnit>(assembly_id, admin_acl, ctx);
    let owner_cap_id = object::id(&owner_cap);

    // 构造 SU 对象本体。
    let mut storage_unit = StorageUnit {
        id: assembly_uid,
        key: storage_unit_key,
        owner_cap_id,
        type_id: type_id,
        status: status::anchor(assembly_id, storage_unit_key),
        location: location::attach(location_hash),
        inventory_keys: vector[],
        energy_source_id: option::some(network_node_id),
        metadata: std::option::some(
            metadata::create_metadata(
                assembly_id,
                storage_unit_key,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        extension: option::none(),
    };

    // 把 SU 的 owner cap 转给指定 Character。
    access::transfer_owner_cap(owner_cap, object::id_address(character));

    // 同步把这个 SU 连接到网络节点。
    network_node.connect_assembly(assembly_id);

    // 创建 SU 主库存。
    let inventory = inventory::create(
        max_capacity,
    );

    // 把主库存 key 记到 inventory_keys 里，并挂到动态字段下。
    storage_unit.inventory_keys.push_back(owner_cap_id);
    df::add(&mut storage_unit.id, owner_cap_id, inventory);

    // 发出创建事件。
    event::emit(StorageUnitCreatedEvent {
        storage_unit_id: assembly_id,
        assembly_key: storage_unit_key,
        owner_cap_id,
        type_id: type_id,
        max_capacity,
        location_hash,
        status: status::status(&storage_unit.status),
    });

    storage_unit
}

// 中文说明：
// 这是 sponsor/admin 把已经创建好的 SU 变成 shared object 的入口。
public fun share_storage_unit(storage_unit: StorageUnit, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    transfer::share_object(storage_unit);
}

// 中文说明：
// 更新 SU 绑定的能源节点。
// 只能在 SU 离线状态下做，避免在线过程中切源造成状态错乱。
public fun update_energy_source(
    storage_unit: &mut StorageUnit,
    network_node: &mut NetworkNode,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    let storage_unit_id = object::id(storage_unit);
    let nwn_id = object::id(network_node);
    assert!(!storage_unit.status.is_online(), EStorageUnitInvalidState);

    network_node.connect_assembly(storage_unit_id);
    storage_unit.energy_source_id = option::some(nwn_id);
}

/// Updates the storage unit's energy source and removes it from the UpdateEnergySources hot potato.
/// Must be called for each storage unit in the hot potato returned by connect_assemblies.
// 中文说明：
// 这是批量重连 energy source 流程中的 SU 侧处理函数。
// 调用方会带一个 hot potato 列表进来，这里负责把当前 SU 从待处理列表里移除，并更新绑定节点。
public fun update_energy_source_connected_storage_unit(
    storage_unit: &mut StorageUnit,
    mut update_energy_sources: UpdateEnergySources,
    network_node: &NetworkNode,
): UpdateEnergySources {
    if (update_energy_sources.update_energy_sources_ids_length() > 0) {
        let storage_unit_id = object::id(storage_unit);
        let found = update_energy_sources.remove_energy_sources_assembly_id(
            storage_unit_id,
        );
        if (found) {
            assert!(!storage_unit.status.is_online(), EStorageUnitInvalidState);
            storage_unit.energy_source_id = option::some(object::id(network_node));
        };
    };
    update_energy_sources
}

//  TODO : Can we generalise this function for all assembly
/// Brings a connected storage unit offline and removes it from the hot potato
/// Must be called for each storage unit in the hot potato list
/// Returns the updated hot potato with the processed storage unit removed
/// After all storage units are processed, call destroy_offline_assemblies to consume the hot potato
/// Used for nwn.offline() flow; keeps the energy source so the storage unit can go online again with the same NWN.
// 中文说明：
// 这个函数服务于 NetworkNode 下线流程。
// 它把一个“仍然连接着该节点”的 SU 拉下线并释放能量，但不会清空能源节点绑定。
public fun offline_connected_storage_unit(
    storage_unit: &mut StorageUnit,
    mut offline_assemblies: OfflineAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): OfflineAssemblies {
    if (offline_assemblies.ids_length() > 0) {
        let storage_unit_id = object::id(storage_unit);
        let found = offline_assemblies.remove_assembly_id(storage_unit_id);
        if (found) {
            bring_offline_and_release_energy(
                storage_unit,
                storage_unit_id,
                network_node,
                energy_config,
            );
        }
    };
    offline_assemblies
}

/// Brings a connected storage unit offline, releases energy, clears energy source, and removes it from the hot potato
/// Must be called for each storage unit in the hot potato returned by nwn.unanchor()
/// Returns the updated HandleOrphanedAssemblies; after all are processed, call destroy_network_node with it
// 中文说明：
// 这个函数和上面不同的点在于：
// 它不仅让 SU 离线，还会把 energy_source_id 清空。
// 适用于能源节点被彻底拆掉、SU 成为 orphan 的场景。
public fun offline_orphaned_storage_unit(
    storage_unit: &mut StorageUnit,
    mut orphaned_assemblies: HandleOrphanedAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): HandleOrphanedAssemblies {
    if (orphaned_assemblies.orphaned_assemblies_length() > 0) {
        let storage_unit_id = object::id(storage_unit);
        let found = orphaned_assemblies.remove_orphaned_assembly_id(storage_unit_id);
        if (found) {
            bring_offline_and_release_energy(
                storage_unit,
                storage_unit_id,
                network_node,
                energy_config,
            );
            storage_unit.energy_source_id = option::none();
        }
    };
    orphaned_assemblies
}

// On unanchor the storage unit is scooped back into inventory in game
// So we burn the items and delete the object
// 中文说明：
// `unanchor` 是“正常拆除仍然挂在某个网络节点上的 SU”。
// 它会：
// 1. 如有必要先释放能量
// 2. 从网络节点断开
// 3. 删除所有库存
// 4. 删除元数据和位置
// 5. 最后删除 SU object 自身
public fun unanchor(
    storage_unit: StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    let StorageUnit {
        mut id,
        key,
        status,
        location,
        inventory_keys,
        metadata,
        energy_source_id,
        type_id,
        ..,
    } = storage_unit;

    // 传入的 network node 必须与当前记录一致。
    assert!(option::is_some(&energy_source_id), ENetworkNodeMismatch);
    assert!(*option::borrow(&energy_source_id) == object::id(network_node), ENetworkNodeMismatch);

    // Release energy if storage unit is online
    // 中文说明：如果当时还在线，需要先把占用的能量释放掉。
    if (status.is_online()) {
        release_energy_by_type(network_node, energy_config, type_id);
    };

    // Disconnect storage unit from network node
    let storage_unit_id = object::uid_to_inner(&id);
    network_node.disconnect_assembly(storage_unit_id);

    status.unanchor(storage_unit_id, key);
    location.remove();

    // loop through inventory_keys
    // 中文说明：删除这个 SU 下挂着的所有库存，无论是主库存还是各个角色个人库存。
    inventory_keys.destroy!(
        |inventory_key| df::remove<ID, Inventory>(&mut id, inventory_key).delete(
            storage_unit_id,
            key,
        ),
    );
    metadata.do!(|metadata| metadata.delete());
    let _ = option::destroy_with_default(energy_source_id, object::id(network_node));
    id.delete();
}

// 中文说明：
// 这个版本用于“孤儿 SU”的拆除，不再依赖 network node 参数。
public fun unanchor_orphan(storage_unit: StorageUnit, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    let StorageUnit {
        mut id,
        key,
        status,
        location,
        inventory_keys,
        metadata,
        energy_source_id,
        ..,
    } = storage_unit;

    location.remove();
    let storage_unit_id = object::uid_to_inner(&id);
    inventory_keys.destroy!(
        |inventory_key| df::remove<ID, Inventory>(&mut id, inventory_key).delete(
            storage_unit_id,
            key,
        ),
    );
    status.unanchor(storage_unit_id, key);
    metadata.do!(|metadata| metadata.delete());
    option::destroy_none(energy_source_id);

    id.delete();
}

/// Bridges items from game to chain inventory
// 中文说明：
// 这是“把游戏里的物品铸造成链上库存记录”的入口。
// 它会在指定 owner_cap 对应的库存中增加物品数量。
// 如果目标 Character 在当前 SU 下还没有个人库存，会先自动建一份。
public fun game_item_to_chain_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    admin_acl: &AdminACL,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    admin_acl.verify_sponsor(ctx);
    let storage_unit_id = object::id(storage_unit);
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());

    // create an owned inventory if it does not exist for a character
    // 中文说明：如果角色库存不存在，就从主库存继承容量上限新建。
    if (!df::exists_(&storage_unit.id, owner_cap_id)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        let inventory = inventory::create(owner_inv.max_capacity());

        storage_unit.inventory_keys.push_back(owner_cap_id);
        df::add(&mut storage_unit.id, owner_cap_id, inventory);
    };

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.mint_items(
        storage_unit_id,
        storage_unit.key,
        character,
        storage_unit.key.tenant(),
        item_id,
        type_id,
        volume,
        quantity,
    )
}

// === Private Functions ===
// 中文说明：
// 私有辅助函数：如果 SU 还在线，就先切离线并释放能量。
fun bring_offline_and_release_energy(
    storage_unit: &mut StorageUnit,
    storage_unit_id: ID,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    if (storage_unit.status.is_online()) {
        storage_unit.status.offline(storage_unit_id, storage_unit.key);
        release_energy(storage_unit, network_node, energy_config);
    };
}

// 中文说明：向能源节点预留当前 SU 类型所需的能量。
fun reserve_energy(
    storage_unit: &StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    let network_node_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .reserve_energy(
            network_node_id,
            energy_config,
            storage_unit.type_id,
        );
}

// 中文说明：按当前 SU 类型释放能量。
fun release_energy(
    storage_unit: &StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    release_energy_by_type(network_node, energy_config, storage_unit.type_id);
}

// 中文说明：按指定 type_id 释放能量。
fun release_energy_by_type(
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    type_id: u64,
) {
    let network_node_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .release_energy(
            network_node_id,
            energy_config,
            type_id,
        );
}

// 中文说明：
// 这是最关键的库存权限校验函数之一。
// 它的规则是：
// 1. 如果传进来的是 `OwnerCap<StorageUnit>`，就允许操作 SU 主库存
// 2. 如果传进来的是 `OwnerCap<Character>`，就允许操作该 Character 个人库存
// 3. 其他任何类型的 OwnerCap 一律拒绝
fun check_inventory_authorization<T: key>(
    owner_cap: &OwnerCap<T>,
    storage_unit: &StorageUnit,
    character_id: ID,
) {
    // If OwnerCap type is StorageUnit then check if authorised object id is storage unit id
    // else if its Character type then the authorized object id is character id
    let owner_cap_type = type_name::with_defining_ids<T>();
    let storage_unit_id = object::id(storage_unit);

    if (owner_cap_type == type_name::with_defining_ids<StorageUnit>()) {
        assert!(access::is_authorized(owner_cap, storage_unit_id), EInventoryNotAuthorized);
    } else if (owner_cap_type == type_name::with_defining_ids<Character>()) {
        assert!(access::is_authorized(owner_cap, character_id), EInventoryNotAuthorized);
    } else {
        assert!(false, EInventoryNotAuthorized);
    };
}

// === Test Functions ===
#[test_only]
public fun inventory_mut(storage_unit: &mut StorageUnit, owner_cap_id: ID): &mut Inventory {
    df::borrow_mut<ID, Inventory>(&mut storage_unit.id, owner_cap_id)
}

#[test_only]
public fun borrow_status_mut(storage_unit: &mut StorageUnit): &mut AssemblyStatus {
    &mut storage_unit.status
}

#[test_only]
public fun item_quantity(storage_unit: &StorageUnit, owner_cap_id: ID, type_id: u64): u32 {
    let inventory = df::borrow<ID, Inventory>(&storage_unit.id, owner_cap_id);
    inventory.item_quantity(type_id)
}

#[test_only]
public fun contains_item(storage_unit: &StorageUnit, owner_cap_id: ID, type_id: u64): bool {
    let inventory = df::borrow<ID, Inventory>(&storage_unit.id, owner_cap_id);
    inventory.contains_item(type_id)
}

#[test_only]
public fun inventory_keys(storage_unit: &StorageUnit): vector<ID> {
    storage_unit.inventory_keys
}

#[test_only]
public fun has_inventory(storage_unit: &StorageUnit, owner_cap_id: ID): bool {
    df::exists_(&storage_unit.id, owner_cap_id)
}

#[test_only]
public fun chain_item_to_game_inventory_test<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    quantity: u32,
    location_proof: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
    let owner_cap_id = object::id(owner_cap);
    check_inventory_authorization(owner_cap, storage_unit, character.id());
    assert!(storage_unit.status.is_online(), ENotOnline);

    let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, owner_cap_id);
    inventory.burn_items_with_proof_test(
        storage_unit_id,
        storage_unit.key,
        character,
        server_registry,
        &storage_unit.location,
        location_proof,
        type_id,
        quantity,
        ctx,
    );
}

#[test_only]
public fun game_item_to_chain_inventory_test<T: key>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());

    // create an owned inventory if it does not exist for a character
    if (!df::exists_(&storage_unit.id, owner_cap_id)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        let inventory = inventory::create(owner_inv.max_capacity());

        storage_unit.inventory_keys.push_back(owner_cap_id);
        df::add(&mut storage_unit.id, owner_cap_id, inventory);
    };

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.mint_items(
        storage_unit_id,
        storage_unit.key,
        character,
        storage_unit.key.tenant(),
        item_id,
        type_id,
        volume,
        quantity,
    )
}
