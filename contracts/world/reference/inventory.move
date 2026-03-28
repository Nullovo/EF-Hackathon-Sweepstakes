// 这是 `world/sources/primitives/inventory.move` 的中文阅读注释版。
// 说明：
// 1. 这份文件用于阅读和审计逻辑，不参与编译。
// 2. 原始 `world` 合约逻辑没有改动，真正参与构建的仍然是 `sources/primitives/inventory.move`。
//
// 这个模块实现的是库存系统的底层原语：
// - 存货
// - 提货
// - 销毁
// - 铸造
// - 容量计算
//
// 这里最重要的设计是：物品分成两种形态，类似 Sui 里的 `Balance` / `Coin`。
//
// - **`ItemEntry`**：静态存放在 `Inventory` 里的账本条目，没有 UID，轻量。
// - **`Item`**：从库存提出来后临时生成的“中转物品 object”，有 UID，可在交易里流转。
//
// `Item` 会携带：
// - `parent_id`：表明它是从哪个 assembly / SU 提出来的
// - `location`：后续可用于位置/距离/接近性校验
//
// # Bridging
//
// 游戏服务端被视为 game 与 chain 之间的可信桥。
//
// - **Game → Chain (mint)：**
//   游戏服务端通过管理员控制的入口，直接把物品铸造成链上库存记录。
// - **Chain → Game (burn)：**
//   链上库存被烧毁，同时发事件，游戏侧监听后在游戏内恢复相应物品。
//
// # Volume
//
// 每个 `type_id` 对应的 `volume` 当前被当作静态值：
// - 第一次 mint / deposit 时写入
// - 后续同 type_id 的容量计算都沿用已存储的 volume
// - 如果外部传来的 volume 不同，当前实现会静默忽略
//
// TODO: volume is currently assumed static per type_id — incoming volume mismatches
// are silently ignored. Volume may change over time and will need proper handling.
module world::inventory;

use std::string::String;
use sui::{clock::Clock, event, vec_map::{Self, VecMap}};
use world::{
    access::ServerAddressRegistry,
    character::Character,
    in_game_id::TenantItemId,
    location::{Self, Location}
};

// === Errors ===
#[error(code = 0)]
const ETypeIdEmpty: vector<u8> = b"Type ID cannot be empty";
#[error(code = 1)]
const EInventoryInvalidCapacity: vector<u8> = b"Inventory Capacity cannot be 0";
#[error(code = 2)]
const EInventoryInsufficientCapacity: vector<u8> = b"Insufficient capacity in the inventory";
#[error(code = 3)]
const EItemDoesNotExist: vector<u8> = b"Item not found";
#[error(code = 4)]
const EInventoryInsufficientQuantity: vector<u8> = b"Insufficient quantity in inventory";
#[error(code = 6)]
const ETypeIdMismatch: vector<u8> = b"Item type_id must match for join operation";
#[error(code = 7)]
const ESplitQuantityInvalid: vector<u8> =
    b"Split quantity must be greater than 0 and less than item quantity";

// === Structs ===

// 链上库存结构。
//
// 它按 `type_id` 记录每种物品的汇总数量。
// `used_capacity` 表示所有物品当前已经占用的总容量：
// `Σ(volume * quantity)`。
//
// 这不是一个独立 key object，而是作为宿主 assembly 的 dynamic field 挂载存在。
//
// 当前实现选用 `VecMap`：
// - 优点：结构相对简单
// - 缺点：查找和插入的复杂度是 O(n)
// - 如果以后库存规模很大，可以再评估是否改成 Table 等结构
public struct Inventory has store {
    // 库存总容量上限。
    max_capacity: u64,
    // 当前已经占用的容量。
    used_capacity: u64,
    // 按 type_id 聚合存储的物品条目。
    items: VecMap<u64, ItemEntry>,
}

// `Inventory` 内部静态存放的物品条目。
//
// 它没有 UID，也不是独立 object，开销很小。
// 可以把它理解成：
// - `ItemEntry` 对应 `Balance`
// - `Item` 对应 `Coin`
//
// 它不会存 `location` 或 `parent_id`；
// 这些信息只会在真正 withdraw 成中转 `Item` 时由上层注入。
public struct ItemEntry has copy, drop, store {
    // 所属 tenant。
    tenant: String,
    // 物品类型 ID。
    type_id: u64,
    // 游戏内物品 ID。
    item_id: u64,
    // 单件体积。
    volume: u64,
    // 当前数量。
    quantity: u32,
}

/// 中转态物品 object。
/// 它在 withdraw 时创建，在 deposit 时销毁。
/// 
/// 因为它带 UID，所以可以作为一等 Sui object 在交易中流转。
/// 但它不是长期存储形态，deposit 后 UID 会被删除。
/// 
/// `parent_id` 记录了它是从哪个 assembly 提出来的。
/// 上层模块（例如 `storage_unit.move`）会在 deposit 时核对这个字段，
/// 防止把来自别的 assembly 的物品乱塞回来。
public struct Item has key, store {
    // 中转物品自身 UID。
    id: UID,
    // 来源 assembly / SU 的 ID。
    parent_id: ID,
    // tenant。
    tenant: String,
    // 物品类型。
    type_id: u64,
    // 游戏物品 ID。
    item_id: u64,
    // 单件体积。
    volume: u64,
    // 数量。
    quantity: u32,
    // 中转时携带的位置元数据。
    location: Location,
}

// === Events ===
public struct ItemMintedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemBurnedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemDepositedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemWithdrawnEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemDestroyedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

// === View Functions ===
// 中文说明：下面这些函数只是简单读取 Item / Inventory 上的字段。
public fun tenant(item: &Item): String {
    item.tenant
}

public fun contains_item(inventory: &Inventory, type_id: u64): bool {
    inventory.items.contains(&type_id)
}

/// Returns the location hash from the transit Item (metadata only, not used for
/// deposit validation — parent_id is used instead).
public fun get_item_location_hash(item: &Item): vector<u8> {
    item.location.hash()
}

/// Returns the object ID of the assembly this item was withdrawn from.
public fun parent_id(item: &Item): ID {
    item.parent_id
}

public fun max_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity
}

public fun type_id(item: &Item): u64 {
    item.type_id
}

public fun quantity(item: &Item): u32 {
    item.quantity
}

// === Package Functions ===

/// 把另一个 `ItemEntry` 合并进当前条目。
/// 两边必须是相同的 `type_id`。
public(package) fun join(entry: &mut ItemEntry, other: ItemEntry) {
    assert!(entry.type_id == other.type_id, ETypeIdMismatch);
    entry.quantity = entry.quantity + other.quantity;
}

public(package) fun create(max_capacity: u64): Inventory {
    // 容量上限不能为 0。
    assert!(max_capacity != 0, EInventoryInvalidCapacity);

    Inventory {
        max_capacity,
        used_capacity: 0,
        items: vec_map::empty(),
    }
}

// 这是“游戏内物品 -> 链上库存”的铸造入口。
// 它是 package 可见，仅允许 world 模块内部调用。
// 这样可以保证不是任何外部人都能随意 mint 库存。
//
// 如果该 `type_id` 已经存在，就在原条目上累加数量；
// 否则创建新的条目。
public(package) fun mint_items(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    tenant: String,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
) {
    assert!(type_id != 0, ETypeIdEmpty);

    // 如果该 type_id 已经存在，则沿用库存里已有的 volume。
    // 这是当前“同 type_id 体积视为静态”的实现假设。
    let effective_volume = if (inventory.items.contains(&type_id)) {
        inventory.items[&type_id].volume
    } else {
        volume
    };

    let req_capacity = calculate_volume(effective_volume, quantity);
    let remaining = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining, EInventoryInsufficientCapacity);
    inventory.used_capacity = inventory.used_capacity + req_capacity;

    let emit_item_id = if (inventory.items.contains(&type_id)) {
        let entry = &mut inventory.items[&type_id];
        entry.quantity = entry.quantity + quantity;
        entry.item_id
    } else {
        inventory.items.insert(type_id, ItemEntry { tenant, type_id, item_id, volume, quantity });
        item_id
    };

    event::emit(ItemMintedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id: emit_item_id,
        type_id,
        quantity,
    });
}

// TODO: remove proximity proof check as it will be handled in the parent module
// 中文说明：
// 这是带位置证明的 burn 入口。
// 当前仍在这里做 proximity proof，后续可以上移到父模块处理。
public(package) fun burn_items_with_proof(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    location: &Location,
    location_proof: vector<u8>,
    type_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes(
        server_registry,
        location,
        location_proof,
        clock,
        ctx,
    );
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}

// 把一个中转态 `Item` 存回库存。
//
// 这一步会：
// 1. 删除 `Item` 的 UID
// 2. 提取里面的数据
// 3. 变回 `ItemEntry`
// 4. 合并到库存已有条目，或创建新条目
//
// 注意：
// 这里不会检查 `parent_id` 是否匹配，
// 这个校验必须由上层模块来做，因为只有上层知道当前 assembly 的真实 ID。
public(package) fun deposit_item(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    item: Item,
) {
    let Item { id, parent_id: _, tenant, type_id, item_id, volume, quantity, location } = item;
    id.delete();
    location.remove();

    // 如果该 type_id 已存在，则沿用库存中记录的 volume。
    let effective_volume = if (inventory.items.contains(&type_id)) {
        inventory.items[&type_id].volume
    } else {
        volume
    };

    let req_capacity = calculate_volume(effective_volume, quantity);
    let remaining = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining, EInventoryInsufficientCapacity);
    inventory.used_capacity = inventory.used_capacity + req_capacity;

    let entry = ItemEntry { tenant, type_id, item_id, volume, quantity };

    let dep_item_id = if (inventory.items.contains(&type_id)) {
        let existing = &mut inventory.items[&type_id];
        let existing_item_id = existing.item_id;
        existing.join(entry);
        existing_item_id
    } else {
        inventory.items.insert(type_id, entry);
        item_id
    };

    event::emit(ItemDepositedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id: dep_item_id,
        type_id,
        quantity,
    });
}

// 从库存中提货，并包装成中转态 `Item` object。
//
// `location_hash` 不直接存放在 `ItemEntry` 中，
// 而是在 withdraw 时由父层注入到新生成的 `Item` 中。
//
// 这里传入的 `assembly_id` 同时也会写入新 `Item` 的 `parent_id`。
public(package) fun withdraw_item(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Item {
    assert!(inventory.items.contains(&type_id), EItemDoesNotExist);
    assert!(quantity > 0, ESplitQuantityInvalid);

    let entry = &inventory.items[&type_id];
    assert!(entry.quantity >= quantity, EInventoryInsufficientQuantity);
    let volume = entry.volume;
    let item_id = entry.item_id;
    let tenant = entry.tenant;

    let capacity_freed = calculate_volume(volume, quantity);
    inventory.used_capacity = inventory.used_capacity - capacity_freed;

    if (entry.quantity == quantity) {
        inventory.items.remove(&type_id);
    } else {
        let entry_mut = &mut inventory.items[&type_id];
        entry_mut.quantity = entry_mut.quantity - quantity;
    };

    event::emit(ItemWithdrawnEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id,
        type_id,
        quantity,
    });

    Item {
        id: object::new(ctx),
        parent_id: assembly_id,
        tenant,
        type_id,
        item_id,
        volume,
        quantity,
        location: location::attach(location_hash),
    }
}

/// 删除整个库存，并对每个条目发出 `ItemDestroyedEvent`。
public(package) fun delete(inventory: Inventory, assembly_id: ID, assembly_key: TenantItemId) {
    let Inventory {
        mut items,
        ..,
    } = inventory;

    // Burn items one by one
    while (!items.is_empty()) {
        let (_, entry) = items.pop();
        event::emit(ItemDestroyedEvent {
            assembly_id,
            assembly_key,
            item_id: entry.item_id,
            type_id: entry.type_id,
            quantity: entry.quantity,
        });
    };
    items.destroy_empty();
}

// 未来可以扩展为库存与库存之间的直接链上转移。
// 但那需要位置证明和距离校验，才能满足“数字物理”约束。
// public fun transfer_items() {}

// === Private Functions ===

// 这是“链上库存 -> 游戏内物品”桥接时的底层 burn 逻辑。
//
// 它会：
// 1. 扣减库存数量
// 2. 如数量归零则移除整条记录
// 3. 释放对应容量
// 4. 发出 `ItemBurnedEvent`
//
// 游戏服务端可以监听该事件，在必要时于游戏侧恢复物品。
fun burn_items(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
) {
    assert!(inventory.items.contains(&type_id), EItemDoesNotExist);

    let entry = &inventory.items[&type_id];
    assert!(entry.quantity >= quantity, EInventoryInsufficientQuantity);
    let item_id = entry.item_id;
    let volume = entry.volume;

    let capacity_freed = calculate_volume(volume, quantity);
    inventory.used_capacity = inventory.used_capacity - capacity_freed;

    if (entry.quantity == quantity) {
        inventory.items.remove(&type_id);
    } else {
        let entry_mut = &mut inventory.items[&type_id];
        entry_mut.quantity = entry_mut.quantity - quantity;
    };

    event::emit(ItemBurnedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id,
        type_id,
        quantity,
    });
}

/// 一个条目占用的总容量：`volume * quantity`。
fun calculate_volume(volume: u64, quantity: u32): u64 {
    volume * (quantity as u64)
}

// === Test Functions ===
// 中文说明：下面这些函数只用于测试断言内部状态。
#[test_only]
public fun remaining_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity - inventory.used_capacity
}

#[test_only]
public fun used_capacity(inventory: &Inventory): u64 {
    inventory.used_capacity
}

#[test_only]
public fun item_quantity(inventory: &Inventory, type_id: u64): u32 {
    inventory.items[&type_id].quantity
}

#[test_only]
public fun item_volume(inventory: &Inventory, type_id: u64): u64 {
    inventory.items[&type_id].volume
}

/// Number of unique type_ids in the inventory.
#[test_only]
public fun inventory_item_length(inventory: &Inventory): u64 {
    inventory.items.length()
}

#[test_only]
public fun burn_items_test(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
) {
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}

// Mocking without deadline
#[test_only]
public fun burn_items_with_proof_test(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    location: &Location,
    location_proof: vector<u8>,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes_without_deadline(
        server_registry,
        location,
        location_proof,
        ctx,
    );
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}
