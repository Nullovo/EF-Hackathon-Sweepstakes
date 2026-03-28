/// 这是 `world/sources/access/access_control.move` 的中文阅读注释版。
/// 说明：
/// 1. 这份文件只用于阅读和审计逻辑，不参与编译。
/// 2. 真正参与构建的仍然是 `sources/access/access_control.move`。
///
/// 这个模块负责 world 体系中的“权限卡 / capability”发放与校验。
///
/// 它定义了三层能力结构：
/// - `GovernorCap`：最高治理能力，用于初始化和治理级控制。
/// - `AdminACL`：共享 ACL，对哪些 sponsor 地址有发卡资格进行登记。
/// - `OwnerCap<T>`：具体对象级的权限卡，授权某个对象被安全修改。
///
/// 你可以把这一层理解成整个系统的门禁中心：
/// - Governor 决定谁能发卡
/// - sponsor 负责发具体对象的卡
/// - 拿到 `OwnerCap<T>` 的流程再去操作对应对象
///
/// 这种设计使得：
/// - 对象本体可以保持共享或固定归属
/// - 权限可以独立转移
/// - 权限边界可以写进类型系统
module world::access;

use std::type_name;
use sui::{event, table::{Self, Table}, transfer::Receiving};
use world::world::GovernorCap;

#[error(code = 0)]
// 角色权限卡不允许直接转给普通地址。
const ECharacterTransfer: vector<u8> = b"Character cannot be transferred";
#[error(code = 1)]
// 当前交易发起人或 sponsor 没有被登记为授权 sponsor。
const EUnauthorizedSponsor: vector<u8> = b"Unauthorized sponsor";
#[error(code = 2)]
// 归还 owner cap 时，receipt 记录的 owner_id 不匹配。
const EOwnerIdMismatch: vector<u8> = b"Owner ID mismatch";
#[error(code = 3)]
// 归还 owner cap 时，receipt 记录的 owner_cap_id 不匹配。
const EOwnerCapIdMismatch: vector<u8> = b"Owner Cap ID mismatch";

/// 这是“借出 OwnerCap 后的归还凭证”。
///
/// 当某张 OwnerCap 是从某个对象（例如 Character）里临时借出来时，
/// 后续如果要：
/// - 原路归还
/// - 或带着凭证完成受控转移
/// 都必须消费对应的这张 receipt。
public struct ReturnOwnerCapReceipt {
    // 这张 owner cap 原本应归还到哪个 owner object/address。
    owner_id: address,
    // 这张 receipt 绑定的是哪一张 owner cap。
    owner_cap_id: ID,
}

// TODO: Add authorized_admins: Table<address, bool> to separate admins and sponsors
public struct AdminACL has key {
    // ACL 对象自身 UID。
    id: UID,
    // 被授权为 sponsor 的地址表。
    authorized_sponsors: Table<address, bool>,
}

/// `OwnerCap<T>` 是对象级的权限卡。
///
/// 它可以理解成一张“某个对象的门禁卡”：
/// - 本身是一个独立 object
/// - 可以被安全转移
/// - 持有者可在特定流程中凭此修改目标对象
///
/// 这里的 `T` 是泛型类型标签：
/// - `OwnerCap<StorageUnit>`
/// - `OwnerCap<Character>`
/// - `OwnerCap<Gate>`
///
/// 注意 `phantom T` 的含义：
/// - `T` 不会真的存进字段
/// - `T` 只参与编译期类型检查
/// - 用来防止不同对象类型的权限卡混用
///
/// 运行时真正存储的核心数据只有：
/// - 这张卡自己的 UID
/// - 它授权到哪个具体对象的 ID
public struct OwnerCap<phantom T> has key {
    // 权限卡对象自身 UID。
    id: UID,
    // 这张卡授权控制的目标对象 ID。
    authorized_object_id: ID,
}

/// 可签发位置证明的服务器地址注册表。
/// 只有更高权限的治理流程才能修改。
public struct ServerAddressRegistry has key {
    // 注册表自身 UID。
    id: UID,
    // 被允许签名位置证明的服务器地址表。
    authorized_address: Table<address, bool>,
}

// === Events ===
public struct OwnerCapCreatedEvent has copy, drop {
    // 新创建的 owner cap ID。
    owner_cap_id: ID,
    // 该 owner cap 授权的目标对象 ID。
    authorized_object_id: ID,
}

public struct OwnerCapTransferred has copy, drop {
    // 被转移的 owner cap ID。
    owner_cap_id: ID,
    // 该 owner cap 授权的目标对象 ID。
    authorized_object_id: ID,
    // 转移前 owner 地址。
    previous_owner: address,
    // 转移后 owner 地址。
    owner: address,
}

fun init(ctx: &mut TxContext) {
    // 初始化服务器地址注册表。
    let server_address_registry = ServerAddressRegistry {
        id: object::new(ctx),
        authorized_address: table::new(ctx),
    };

    // 初始化 sponsor ACL。
    let admin_acl = AdminACL {
        id: object::new(ctx),
        authorized_sponsors: table::new(ctx),
    };

    // 共享出去，便于全局读取和后续验证。
    transfer::share_object(server_address_registry);
    transfer::share_object(admin_acl);
}

// === Public Functions ===

// 当前 OwnerCap 的转移仍然通过受控合约逻辑来完成。
// 未来如果要支持更自由的权限流转，可以在这一层放开。
/// 最基础的 OwnerCap 转移函数。
///
/// 安全性主要依赖 Sui runtime 的对象所有权规则：
/// 只有当前真正拥有这张 OwnerCap 的人，
/// 才能把它作为输入带进交易并完成转移。
public fun transfer_owner_cap<T: key>(owner_cap: OwnerCap<T>, owner: address) {
    transfer::transfer(owner_cap, owner);
}

public fun transfer_owner_cap_to_address<T: key>(
    owner_cap: OwnerCap<T>,
    new_owner: address,
    ctx: &mut TxContext,
) {
    // `OwnerCap<Character>` 不允许直接转给普通地址。
    // 角色权限卡必须继续通过 Character 的借还流程来管理。
    let cap_type = type_name::with_defining_ids<T>();
    let is_character =
        cap_type.module_string() == std::ascii::string(b"character")
        && cap_type.datatype_string() == std::ascii::string(b"Character");
    assert!(!is_character, ECharacterTransfer);
    // 真正转移时会经过私有 `transfer`，顺便发转移事件。
    transfer<T>(owner_cap, ctx.sender(), new_owner);
}

/// 把借出来的 owner cap 归还给原对象。
/// 这个过程必须消费配套的 `ReturnOwnerCapReceipt`。
public fun return_owner_cap_to_object<T: key>(
    owner_cap: OwnerCap<T>,
    receipt: ReturnOwnerCapReceipt,
    owner_id: address,
) {
    // 先验证 receipt 与当前这张 cap、目标 owner 是否匹配。
    validate_return_receipt(receipt, object::id(&owner_cap), owner_id);
    // 验证通过后原路转回。
    transfer_owner_cap(owner_cap, owner_id);
}

/// 消费 receipt，把“借出来的 owner cap”直接转移给一个地址。
public fun transfer_owner_cap_with_receipt<T: key>(
    owner_cap: OwnerCap<T>,
    receipt: ReturnOwnerCapReceipt,
    new_owner: address,
    ctx: &mut TxContext,
) {
    // 这里重点检查 receipt 里记的 cap_id 必须就是当前这张 cap。
    let ReturnOwnerCapReceipt { owner_id: _, owner_cap_id: receipt_owner_cap_id } = receipt;
    assert!(receipt_owner_cap_id == object::id(&owner_cap), EOwnerCapIdMismatch);
    transfer_owner_cap_to_address(owner_cap, new_owner, ctx);
}

// === View Functions ===
/// 检查某个地址是否被登记为可用服务器地址。
public fun is_authorized_server_address(
    server_address_registry: &ServerAddressRegistry,
    address: address,
): bool {
    server_address_registry.authorized_address.contains(address)
}

// 检查一张 `OwnerCap` 是否授权到指定对象。
/// 这是 OwnerCap 校验的核心函数。
///
/// 它的逻辑很直接：
/// - 读取 `owner_cap.authorized_object_id`
/// - 看是否等于传入的 `object_id`
///
/// 因此 OwnerCap 校验分两层：
/// - 编译期：由泛型 `T` 保证“卡的类别正确”
/// - 运行时：由这个函数保证“卡的目标对象正确”
public fun is_authorized<T: key>(owner_cap: &OwnerCap<T>, object_id: ID): bool {
    owner_cap.authorized_object_id == object_id
}

/// 验证当前交易是否来自被授权 sponsor。
///
/// 规则是：
/// - 如果交易是 sponsored transaction，就检查 sponsor 地址
/// - 否则就检查 sender 地址
public fun verify_sponsor(admin_acl: &AdminACL, ctx: &TxContext) {
    let sponsor_opt = tx_context::sponsor(ctx);
    let authorized_address = if (option::is_some(&sponsor_opt)) {
        *option::borrow(&sponsor_opt)
    } else {
        ctx.sender()
    };
    assert!(admin_acl.authorized_sponsors.contains(authorized_address), EUnauthorizedSponsor);
}

// === Package Functions ===
/// 创建一张 OwnerCap，并立刻转给指定 owner。
/// 这是 world 包内部的便捷辅助函数。
public(package) fun create_and_transfer_owner_cap<T: key>(
    object_id: ID,
    admin_acl: &AdminACL,
    owner: address,
    ctx: &mut TxContext,
): ID {
    // 先创建 owner cap。
    let owner_cap = create_owner_cap_by_id<T>(object_id, admin_acl, ctx);
    // 记录新卡的 object id。
    let owner_cap_id = object::id(&owner_cap);
    // 再转给指定 owner。
    transfer<T>(owner_cap, @0x0, owner);
    owner_cap_id
}

/// 从 `Receiving<OwnerCap<T>>` ticket 中真正接收出一张 OwnerCap。
///
/// 常见流程：
/// - 某个 Character 下面挂着 OwnerCap
/// - 前端发起 PTB 时先把它借出来
/// - 业务逻辑用完后再配合 receipt 还回去
public(package) fun receive_owner_cap<T: key>(
    receiving_id: &mut UID,
    ticket: Receiving<OwnerCap<T>>,
): OwnerCap<T> {
    transfer::receive(receiving_id, ticket)
}

/// 创建“归还凭证”。
/// 后续必须由受控归还 / 转移函数消费。
public(package) fun create_return_receipt(
    owner_cap_id: ID,
    owner_id: address,
): ReturnOwnerCapReceipt {
    ReturnOwnerCapReceipt { owner_id, owner_cap_id }
}

// === Admin Functions ===
/// 给 ACL 增加 sponsor。
/// 只有 GovernorCap 能做这件事。
public fun add_sponsor_to_acl(
    admin_acl: &mut AdminACL,
    _: &GovernorCap,
    sponsor: address,
) {
    admin_acl.authorized_sponsors.add(sponsor, true);
}

/// 基于一个真实对象引用创建 OwnerCap。
/// 它会自动读取对象 ID 并发卡。
public fun create_owner_cap<T: key>(
    admin_acl: &AdminACL,
    obj: &T,
    ctx: &mut TxContext,
): OwnerCap<T> {
    // 只有 sponsor 才能发卡。
    admin_acl.verify_sponsor(ctx);
    // 读取目标对象 ID。
    let object_id = object::id(obj);
    // 构造 owner cap。
    let owner_cap = OwnerCap<T> {
        id: object::new(ctx),
        authorized_object_id: object_id,
    };
    // 发创建事件。
    event::emit(OwnerCapCreatedEvent {
        owner_cap_id: object::id(&owner_cap),
        authorized_object_id: object_id,
    });
    owner_cap
}

/// 直接基于 object_id 创建 OwnerCap。
/// 适合对象还在创建过程中、手头只有对象 ID 的场景。
public fun create_owner_cap_by_id<T: key>(
    object_id: ID,
    admin_acl: &AdminACL,
    ctx: &mut TxContext,
): OwnerCap<T> {
    // 同样只有 sponsor 才能发卡。
    admin_acl.verify_sponsor(ctx);
    let owner_cap = OwnerCap<T> {
        id: object::new(ctx),
        authorized_object_id: object_id,
    };
    event::emit(OwnerCapCreatedEvent {
        owner_cap_id: object::id(&owner_cap),
        authorized_object_id: object_id,
    });
    owner_cap
}

/// 把某个服务器地址登记为可用于位置证明签名的地址。
public fun register_server_address(
    server_address_registry: &mut ServerAddressRegistry,
    _: &GovernorCap,
    server_address: address,
) {
    server_address_registry.authorized_address.add(server_address, true);
}

/// 从服务器地址注册表中移除某个地址。
public fun remove_server_address(
    server_address_registry: &mut ServerAddressRegistry,
    _: &GovernorCap,
    server_address: address,
) {
    server_address_registry.authorized_address.remove(server_address);
}

/// 删除一张 owner cap。
/// 同样只有 sponsor 才能执行。
public fun delete_owner_cap<T: key>(owner_cap: OwnerCap<T>, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    let OwnerCap { id, .. } = owner_cap;
    id.delete();
}

// === Private Functions ===
/// 真正执行 OwnerCap 转移的私有辅助函数。
/// 它会先发 `OwnerCapTransferred` 事件，再调用底层 transfer。
fun transfer<T: key>(owner_cap: OwnerCap<T>, previous_owner: address, new_owner: address) {
    event::emit(OwnerCapTransferred {
        owner_cap_id: object::id(&owner_cap),
        authorized_object_id: owner_cap.authorized_object_id,
        previous_owner: previous_owner,
        owner: new_owner,
    });
    transfer::transfer(owner_cap, new_owner);
}

/// 校验归还凭证。
/// 这里会同时检查：
/// - receipt 里的 owner_id 是否等于预期 owner
/// - receipt 里的 owner_cap_id 是否等于当前这张 cap
fun validate_return_receipt(receipt: ReturnOwnerCapReceipt, owner_cap_id: ID, owner_id: address) {
    let ReturnOwnerCapReceipt {
        owner_id: receipt_owner_id,
        owner_cap_id: receipt_owner_cap_id,
    } = receipt;
    assert!(receipt_owner_id == owner_id, EOwnerIdMismatch);
    assert!(receipt_owner_cap_id == owner_cap_id, EOwnerCapIdMismatch);
}

#[test_only]
// 测试辅助：显式销毁 receipt。
public fun destroy_receipt_for_testing(receipt: ReturnOwnerCapReceipt) {
    let ReturnOwnerCapReceipt { owner_id: _, owner_cap_id: _ } = receipt;
}

#[test_only]
// 测试辅助：执行 init。
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
