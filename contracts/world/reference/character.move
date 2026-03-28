/// 这是 `world/sources/character/character.move` 的中文阅读注释版。
/// 说明：
/// 1. 这份文件用于阅读和审计逻辑，不参与编译。
/// 2. 原始 `world` 合约逻辑没有改动，真正参与构建的仍然是 `sources/character/character.move`。
///
/// 这个模块负责 Character 的创建、共享、元数据更新以及 OwnerCap 借还流程。
///
/// 这里的 Character 不是简单“钱包地址映射”对象，而是：
/// - 一个共享对象；
/// - 拥有独立的 owner capability；
/// - 可被管理员或持有对应 capability 的流程安全地访问。
///
/// Game characters have flexible ownership and access control beyond simple wallet-based ownership.
/// Characters are shared objects and mutable by admin and the character owner using capabilities.

module world::character;

use std::string::String;
use sui::{derived_object, event, transfer::Receiving};
use world::{
    access::{Self, AdminACL, OwnerCap},
    in_game_id::{Self, TenantItemId},
    metadata::{Self, Metadata},
    object_registry::ObjectRegistry
};

#[error(code = 0)]
const EGameCharacterIdEmpty: vector<u8> = b"Game character ID is empty";

#[error(code = 1)]
const ETribeIdEmpty: vector<u8> = b"Tribe ID is empty";

#[error(code = 2)]
const ECharacterAlreadyExists: vector<u8> = b"Character with this game character ID already exists";

#[error(code = 3)]
const ETenantEmpty: vector<u8> = b"Tenant name cannot be empty";

#[error(code = 4)]
const EAddressEmpty: vector<u8> = b"Address cannot be empty";

#[error(code = 5)]
const ESenderCannotAccessCharacter: vector<u8> = b"Sender cannot access Character";
#[error(code = 6)]
const EMetadataNotSet: vector<u8> = b"Metadata not set on character";
#[error(code = 7)]
const ECharacterNotAuthorized: vector<u8> = b"Character access not authorized";

public struct Character has key {
    // Character 自身的 UID。
    id: UID,
    // 角色业务键，用于派生链上对象 ID。
    // 它通常由 game_character_id + tenant 共同构成。
    key: TenantItemId, // The derivation key used to generate the character's object ID
    // 角色所属 tribe。
    tribe_id: u32,
    // 当前角色绑定的钱包地址。
    character_address: address,
    // 可选元数据，如名称、描述、URL。
    metadata: Option<Metadata>,
    // Character 自己的 OwnerCap 对象 ID。
    // 以后角色的个人权限、库存绑定等，都会依赖这个字段。
    owner_cap_id: ID,
}

/// 临时查询辅助对象：
/// - 每个 Character 会额外生成一个 `PlayerProfile`
/// - 它会被转到 `character_address`
/// - 这样客户端就可以通过“按钱包查对象”的方式，反查到 character_id
///
/// Temporary struct for wallet-owned query: one per character, transferred to character_address.
/// Points at the character so clients can query "objects by wallet" and get character_id.
public struct PlayerProfile has key {
    // PlayerProfile 自身 UID。
    id: UID,
    // 对应的 Character ID。
    character_id: ID,
}

// Events
// 中文说明：Character 创建后会发一个创建事件，便于前端或索引器收集角色列表。
public struct CharacterCreatedEvent has copy, drop {
    // 新建角色的对象 ID。
    character_id: ID,
    // 角色业务键。
    key: TenantItemId,
    // tribe id。
    tribe_id: u32,
    // 绑定的钱包地址。
    character_address: address,
}

// === View Functions ===
// 中文说明：下面这些函数都是只读 getter，用于从 Character 上取字段。
public fun id(character: &Character): ID {
    object::id(character)
}

public fun key(character: &Character): TenantItemId {
    character.key
}

public fun character_address(character: &Character): address {
    character.character_address
}

public fun tenant(character: &Character): String {
    in_game_id::tenant(&character.key)
}

public fun tribe(character: &Character): u32 {
    character.tribe_id
}

public fun owner_cap_id(character: &Character): ID {
    character.owner_cap_id
}

// === Public Functions ===
// 中文说明：
// 下面三个函数分别用于更新 Character 的 metadata 字段。
// 它们都要求：
// 1. 传入的 OwnerCap<Character> 确实授权到这个 Character
// 2. metadata 当前已经存在
public fun update_metadata_name(
    character: &mut Character,
    owner_cap: &OwnerCap<Character>,
    name: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(character)), ECharacterNotAuthorized);
    assert!(std::option::is_some(&character.metadata), EMetadataNotSet);
    let metadata = std::option::borrow_mut(&mut character.metadata);
    metadata.update_name(character.key, name);
}

public fun update_metadata_description(
    character: &mut Character,
    owner_cap: &OwnerCap<Character>,
    description: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(character)), ECharacterNotAuthorized);
    assert!(std::option::is_some(&character.metadata), EMetadataNotSet);
    let metadata = std::option::borrow_mut(&mut character.metadata);
    metadata.update_description(character.key, description);
}

public fun update_metadata_url(
    character: &mut Character,
    owner_cap: &OwnerCap<Character>,
    url: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(character)), ECharacterNotAuthorized);
    assert!(std::option::is_some(&character.metadata), EMetadataNotSet);
    let metadata = std::option::borrow_mut(&mut character.metadata);
    metadata.update_url(character.key, url);
}

// === Admin Functions ===
// 中文说明：
// `create_character` 是管理员创建角色的主入口。
// 它会：
// 1. 校验 game_character_id / tenant / tribe / address
// 2. 通过 registry + TenantItemId 派生一个确定性的 Character object id
// 3. 创建 OwnerCap<Character>
// 4. 初始化 Character 元数据
// 5. 给钱包地址发一个 PlayerProfile
// 6. 发出 CharacterCreatedEvent
public fun create_character(
    registry: &mut ObjectRegistry,
    admin_acl: &AdminACL,
    game_character_id: u32,
    tenant: String,
    tribe_id: u32,
    character_address: address,
    name: String,
    ctx: &mut TxContext,
): Character {
    assert!(game_character_id != 0, EGameCharacterIdEmpty);
    assert!(tribe_id != 0, ETribeIdEmpty);
    assert!(character_address != @0x0, EAddressEmpty);
    assert!(tenant.length() > 0, ETenantEmpty);

    // 用 game_character_id + tenant 生成业务键。
    // 这样同一业务角色在链上的 object id 是可预测、可复算、不可重复创建的。
    // Claim a derived UID using the game character id and tenant id as the key
    // This ensures deterministic character id  generation and prevents duplicate character creation under the same game id.
    // The character id can be pre-computed using the registry object id and TenantItemId
    let character_key = in_game_id::create_key(game_character_id as u64, tenant);
    assert!(!registry.object_exists(character_key), ECharacterAlreadyExists);
    let character_uid = derived_object::claim(registry.borrow_registry_id(), character_key);
    let character_id = object::uid_to_inner(&character_uid);

    let owner_cap = access::create_owner_cap_by_id<Character>(character_id, admin_acl, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let character = Character {
        id: character_uid,
        key: character_key,
        tribe_id,
        character_address,
        metadata: std::option::some(
            metadata::create_metadata(
                character_id,
                character_key,
                name,
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        owner_cap_id,
    };

    access::transfer_owner_cap(owner_cap, object::id_address(&character));

    // 生成一个临时 PlayerProfile，并转给玩家钱包地址。
    // 这样前端可以通过“按钱包查对象”来找到 Character。
    // 后续如果改为更正式的 OwnerCap-to-wallet 流程，这里可以替换。
    // Create a temporary PlayerProfile and transfer it to the player's wallet address (character_address)
    // so clients can query characters by wallet. TODO: Replace with Character OwnerCap-to-wallet flow.
    let player_profile = PlayerProfile {
        id: object::new(ctx),
        character_id: object::id(&character),
    };
    transfer::transfer(player_profile, character_address);

    event::emit(CharacterCreatedEvent {
        character_id: object::id(&character),
        key: character_key,
        tribe_id,
        character_address,
    });
    character
}

// 从 Character 对象中临时借出某个 OwnerCap。
// 常见场景：
// - 前端先把 `OwnerCap<StorageUnit>` 转给 Character
// - 调用这里临时取出来做一个 PTB
// - 用完后再 return 回去
// refer : https://docs.sui.io/guides/developer/objects/transfers/transfer-to-object for more details
public fun borrow_owner_cap<T: key>(
    character: &mut Character,
    owner_cap_ticket: Receiving<OwnerCap<T>>,
    ctx: &TxContext,
): (OwnerCap<T>, access::ReturnOwnerCapReceipt) {
    // 只有角色绑定的钱包地址才能借出 Character 里持有的 owner cap。
    assert!(character.character_address == ctx.sender(), ESenderCannotAccessCharacter);

    // 从 Character 对象中接收指定的 OwnerCap。
    let owner_cap = access::receive_owner_cap(&mut character.id, owner_cap_ticket);
    // 创建“归还凭证”，确保后续 return 的是同一份 owner cap。
    let return_receipt = access::create_return_receipt(
        object::id(&owner_cap),
        object::id_address(character),
    );
    (owner_cap, return_receipt)
}

// 把借出的 OwnerCap 原路还回 Character。
public fun return_owner_cap<T: key>(
    character: &Character,
    owner_cap: OwnerCap<T>,
    receipt: access::ReturnOwnerCapReceipt,
) {
    access::return_owner_cap_to_object(owner_cap, receipt, object::id_address(character));
}

// 把 Character 共享出去。
public fun share_character(character: Character, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    transfer::share_object(character);
}

// 管理员更新 tribe。
public fun update_tribe(
    character: &mut Character,
    admin_acl: &AdminACL,
    tribe_id: u32,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(tribe_id != 0, ETribeIdEmpty);
    character.tribe_id = tribe_id;
}

/// 更新角色绑定的钱包地址。
/// 注意：
/// - 旧地址上已经存在的 `PlayerProfile` 不会自动移动
/// - 所以客户端如果按新地址查，可能暂时查不到旧的 profile
/// - 后续更理想的方案是改成 ownercap-to-wallet 流程
///
/// Updates the character's wallet address. Note: any existing PlayerProfile remains at the old
/// wallet; clients querying by the new address will not see it until a new profile is issued.
/// TODO: Replace with transferring character ownercap to wallet address later
public fun update_address(
    character: &mut Character,
    admin_acl: &AdminACL,
    character_address: address,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(character_address != @0x0, EAddressEmpty);
    character.character_address = character_address;
}

// 紧急修正 tenant 时使用。
public fun update_tenant_id(
    character: &mut Character,
    admin_acl: &AdminACL,
    tenant: String,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(tenant.length() > 0, ETenantEmpty);
    let current_id = in_game_id::item_id(&character.key);
    character.key = in_game_id::create_key(current_id, tenant);
}

/// 删除 Character。
/// 注意：
/// - 这里只删除 Character 本体和它的 metadata
/// - 如果外部钱包还持有旧的 PlayerProfile，这里不会顺手清理
/// - 这也是当前“临时 profile 方案”的一个限制
///
/// Deletes the character and its metadata. PlayerProfile (if any) is wallet-owned and not
/// cleaned up here; it will be obsolete once replaced by the OwnerCap-to-wallet flow.
public fun delete_character(character: Character, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    let Character { id, metadata, .. } = character;
    if (std::option::is_some(&metadata)) {
        let m = std::option::destroy_some(metadata);
        metadata::delete(m);
    } else {
        std::option::destroy_none(metadata);
    };
    id.delete();
}

// === Test Functions ===
// 中文说明：下面这些函数只用于测试环境，便于断言内部字段。
#[test_only]
public fun game_character_id(character: &Character): u32 {
    in_game_id::item_id(&character.key) as u32
}

#[test_only]
public fun tribe_id(character: &Character): u32 {
    character.tribe_id
}

#[test_only]
public fun name(character: &Character): String {
    let metadata = std::option::borrow(&character.metadata);
    metadata::name(metadata)
}

#[test_only]
public fun mutable_metadata(character: &mut Character): &mut Metadata {
    std::option::borrow_mut(&mut character.metadata)
}
