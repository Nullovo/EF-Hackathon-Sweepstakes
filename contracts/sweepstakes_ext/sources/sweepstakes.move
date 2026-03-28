module extension_examples::sweepstakes;

use std::string::String;
use sui::balance::{Self as balance, Balance};
use sui::coin::{Self as coin, Coin};
use sui::dynamic_field as df;
use sui::event;
use sui::random::{Self as random, Random};
use sui::{bcs, hash};
use assets::EVE::EVE;
use world::access::{Self as access, OwnerCap};
use world::character::{Self as character, Character};
use world::inventory::Item;
use world::storage_unit::{Self as storage_unit, StorageUnit};

#[error(code = 0)]
const ETotalTicketsMustBePositive: vector<u8> = b"Total tickets must be greater than 0";
#[error(code = 1)]
const ETicketPriceMustBePositive: vector<u8> = b"Ticket price must be greater than 0";
#[error(code = 2)]
const EPrizeQuantityMustBePositive: vector<u8> = b"Prize quantity must be greater than 0";
#[error(code = 4)]
const ECharacterSenderMismatch: vector<u8> = b"Character address must match the transaction sender";
#[error(code = 5)]
const EGameNotOpen: vector<u8> = b"Lottery game is not open";
#[error(code = 6)]
const ETicketCountMustBePositive: vector<u8> = b"Ticket count must be greater than 0";
#[error(code = 7)]
const ETicketsSoldOut: vector<u8> = b"Not enough remaining tickets";
#[error(code = 8)]
const EInsufficientPayment: vector<u8> = b"Payment is smaller than the required EVE amount";
#[error(code = 9)]
const EOnlyCreatorCanCancel: vector<u8> = b"Only the creator can cancel the lottery";
#[error(code = 10)]
const ENotSoldOut: vector<u8> = b"Lottery can be drawn only after all tickets are sold";
#[error(code = 11)]
const EWinnerAlreadyDrawn: vector<u8> = b"Winner has already been drawn";
#[error(code = 12)]
const EWinnerNotDrawn: vector<u8> = b"Winner has not been drawn yet";
#[error(code = 13)]
const EOnlyWinnerCanClaim: vector<u8> = b"Only the recorded winner can claim the prize";
#[error(code = 14)]
const EWinnerCharacterMismatch: vector<u8> = b"Winner character does not match the recorded winner";
#[error(code = 15)]
const EStorageUnitMismatch: vector<u8> = b"Storage unit does not match the lottery's bound storage unit";
#[error(code = 16)]
const EPrizeAlreadyClaimed: vector<u8> = b"Prize has already been removed from escrow";
#[error(code = 17)]
const ETicketRecordNotFound: vector<u8> = b"Ticket record was not found";
#[error(code = 18)]
const EGameNotDrawableOrClaimable: vector<u8> =
    b"Lottery game is not in a drawable or claimable state";
#[error(code = 19)]
const ECreatorCharacterMismatch: vector<u8> = b"Creator character does not match the recorded creator";
#[error(code = 20)]
const ECannotCancelSoldOutGame: vector<u8> = b"Sold out lottery can no longer be canceled";

const STATE_OPEN: u8 = 0;
const STATE_DRAWN: u8 = 1;
const STATE_SETTLED: u8 = 2;
const STATE_CANCELED: u8 = 3;

#[error(code = 21)]
const EStorageUnitOwnerRequired: vector<u8> =
    b"Only the storage unit owner can authorize the sweepstakes extension";

public struct SweepstakesAuth has drop {}

public struct TicketPurchase has copy, drop, store {
    buyer: address,
    character_id: ID,
    start_ticket: u64,
    ticket_count: u64,
    paid_amount: u64,
}

public struct TicketReceipt has copy, drop, store {
    holder: address,
    character_id: ID,
    ticket_number: u64,
    ticket_hash: vector<u8>,
}

public struct WinnerSnapshot has copy, drop, store {
    player: address,
    character_id: ID,
    ticket_number: u64,
    ticket_hash: vector<u8>,
}

public struct TicketHashSeed has copy, drop, store {
    game_id: ID,
    buyer: address,
    character_id: ID,
    ticket_number: u64,
}

public struct LotteryGame has key {
    id: UID,
    storage_unit_id: ID,
    creator: address,
    creator_character_id: ID,
    title: String,
    ticket_price: u64,
    total_tickets: u64,
    sold_tickets: u64,
    prize_type_id: u64,
    prize_quantity: u32,
    prize: Option<Item>,
    sale_proceeds: Balance<EVE>,
    purchases: vector<TicketPurchase>,
    winning_ticket: Option<u64>,
    winner: Option<WinnerSnapshot>,
    state: u8,
}

public struct GameCreatedEvent has copy, drop {
    game_id: ID,
    storage_unit_id: ID,
    creator: address,
    creator_character_id: ID,
    ticket_price: u64,
    total_tickets: u64,
    prize_type_id: u64,
    prize_quantity: u32,
}

public struct TicketIssuedEvent has copy, drop {
    game_id: ID,
    holder: address,
    character_id: ID,
    ticket_number: u64,
    ticket_hash: vector<u8>,
}

public struct TicketsPurchasedEvent has copy, drop {
    game_id: ID,
    buyer: address,
    character_id: ID,
    start_ticket: u64,
    ticket_count: u64,
    paid_amount: u64,
    sold_tickets: u64,
}

public struct WinnerDrawnEvent has copy, drop {
    game_id: ID,
    winner: address,
    winner_character_id: ID,
    winning_ticket: u64,
    winning_ticket_hash: vector<u8>,
    creator_payout: u64,
}

public struct PrizeClaimedEvent has copy, drop {
    game_id: ID,
    winner: address,
    winner_character_id: ID,
    prize_type_id: u64,
    prize_quantity: u32,
}

public struct GameCanceledEvent has copy, drop {
    game_id: ID,
    creator: address,
    refunded_amount: u64,
}

public fun create_game(
    storage_unit_obj: &mut StorageUnit,
    creator_character: &Character,
    creator_character_owner_cap: OwnerCap<Character>,
    title: String,
    prize_type_id: u64,
    prize_quantity: u32,
    ticket_price: u64,
    total_tickets: u64,
    ctx: &mut TxContext,
): (LotteryGame, OwnerCap<Character>) {
    assert!(total_tickets > 0, ETotalTicketsMustBePositive);
    assert!(ticket_price > 0, ETicketPriceMustBePositive);
    assert!(prize_quantity > 0, EPrizeQuantityMustBePositive);
    assert_sender_matches_character(creator_character, ctx);

    let storage_unit_id = object::id(storage_unit_obj);
    let prize = storage_unit::withdraw_by_owner(
        storage_unit_obj,
        creator_character,
        &creator_character_owner_cap,
        prize_type_id,
        prize_quantity,
        ctx,
    );

    let creator = ctx.sender();
    let creator_character_id = character::id(creator_character);

    let game = LotteryGame {
        id: object::new(ctx),
        storage_unit_id,
        creator,
        creator_character_id,
        title,
        ticket_price,
        total_tickets,
        sold_tickets: 0,
        prize_type_id,
        prize_quantity,
        prize: option::some(prize),
        sale_proceeds: balance::zero(),
        purchases: vector[],
        winning_ticket: option::none(),
        winner: option::none(),
        state: STATE_OPEN,
    };

    event::emit(GameCreatedEvent {
        game_id: object::id(&game),
        storage_unit_id,
        creator,
        creator_character_id,
        ticket_price,
        total_tickets,
        prize_type_id,
        prize_quantity,
    });

    (game, creator_character_owner_cap)
}

public fun share_game(game: LotteryGame) {
    transfer::share_object(game);
}

public fun authorize_sweepstakes_extension(
    storage_unit_obj: &mut StorageUnit,
    owner_character: &Character,
    storage_unit_owner_cap: OwnerCap<StorageUnit>,
    ctx: &TxContext,
): OwnerCap<StorageUnit> {
    assert_sender_matches_character(owner_character, ctx);
    assert!(
        access::is_authorized(&storage_unit_owner_cap, object::id(storage_unit_obj)),
        EStorageUnitOwnerRequired,
    );

    storage_unit::authorize_extension<SweepstakesAuth>(
        storage_unit_obj,
        &storage_unit_owner_cap,
    );

    storage_unit_owner_cap
}

entry fun buy_tickets(
    game: &mut LotteryGame,
    buyer_character: &Character,
    mut payment: Coin<EVE>,
    ticket_count: u64,
    randomness: &Random,
    ctx: &mut TxContext,
) {
    assert!(game.state == STATE_OPEN, EGameNotOpen);
    assert!(ticket_count > 0, ETicketCountMustBePositive);
    assert_sender_matches_character(buyer_character, ctx);
    assert!(game.sold_tickets + ticket_count <= game.total_tickets, ETicketsSoldOut);

    let required_amount = game.ticket_price * ticket_count;
    let payment_value = coin::value(&payment);
    assert!(payment_value >= required_amount, EInsufficientPayment);

    let start_ticket = game.sold_tickets;
    let buyer = ctx.sender();
    let buyer_character_id = character::id(buyer_character);

    if (payment_value > required_amount) {
        let change_amount = payment_value - required_amount;
        let change = coin::split(&mut payment, change_amount, ctx);
        transfer::public_transfer(change, buyer);
    };

    balance::join(&mut game.sale_proceeds, coin::into_balance(payment));

    issue_tickets(game, buyer, buyer_character_id, start_ticket, ticket_count);

    vector::push_back(
        &mut game.purchases,
        TicketPurchase {
            buyer,
            character_id: buyer_character_id,
            start_ticket,
            ticket_count,
            paid_amount: required_amount,
        },
    );

    game.sold_tickets = game.sold_tickets + ticket_count;

    event::emit(TicketsPurchasedEvent {
        game_id: object::id(game),
        buyer,
        character_id: buyer_character_id,
        start_ticket,
        ticket_count,
        paid_amount: required_amount,
        sold_tickets: game.sold_tickets,
    });

    if (game.sold_tickets == game.total_tickets) {
        draw_winner_internal(game, randomness, ctx);
    };
}

fun draw_winner_internal(game: &mut LotteryGame, randomness: &Random, ctx: &mut TxContext) {
    assert!(game.state == STATE_OPEN, EGameNotOpen);
    assert!(game.sold_tickets == game.total_tickets, ENotSoldOut);
    assert!(option::is_none(&game.winner), EWinnerAlreadyDrawn);

    let mut generator = random::new_generator(randomness, ctx);
    let winning_ticket =
        random::generate_u64_in_range(&mut generator, 0, game.total_tickets - 1);
    let ticket = ticket_receipt_internal(game, winning_ticket);
    let winner = WinnerSnapshot {
        player: ticket.holder,
        character_id: ticket.character_id,
        ticket_number: ticket.ticket_number,
        ticket_hash: ticket.ticket_hash,
    };
    let creator_payout = balance::value(&game.sale_proceeds);

    game.winning_ticket = option::some(winning_ticket);
    game.winner = option::some(winner);
    game.state = STATE_DRAWN;

    pay_creator(game, ctx);

    event::emit(WinnerDrawnEvent {
        game_id: object::id(game),
        winner: ticket.holder,
        winner_character_id: ticket.character_id,
        winning_ticket,
        winning_ticket_hash: ticket.ticket_hash,
        creator_payout,
    });
}

public fun claim_prize(
    game: &mut LotteryGame,
    storage_unit_obj: &mut StorageUnit,
    winner_character: &Character,
    winner_character_owner_cap: OwnerCap<Character>,
    ctx: &mut TxContext,
): OwnerCap<Character> {
    assert!(game.state == STATE_DRAWN, EGameNotDrawableOrClaimable);
    assert_storage_unit_matches(game, storage_unit_obj);
    assert_sender_matches_character(winner_character, ctx);

    let winner = winner_snapshot(game);
    assert!(ctx.sender() == winner.player, EOnlyWinnerCanClaim);
    assert!(
        character::id(winner_character) == winner.character_id,
        EWinnerCharacterMismatch,
    );

    let prize = take_prize(game);

    storage_unit::deposit_to_owned<SweepstakesAuth>(
        storage_unit_obj,
        winner_character,
        prize,
        SweepstakesAuth {},
        ctx,
    );

    game.state = STATE_SETTLED;

    event::emit(PrizeClaimedEvent {
        game_id: object::id(game),
        winner: winner.player,
        winner_character_id: winner.character_id,
        prize_type_id: game.prize_type_id,
        prize_quantity: game.prize_quantity,
    });

    winner_character_owner_cap
}

public fun cancel_game(
    game: &mut LotteryGame,
    storage_unit_obj: &mut StorageUnit,
    creator_character: &Character,
    creator_character_owner_cap: OwnerCap<Character>,
    ctx: &mut TxContext,
): OwnerCap<Character> {
    assert!(game.state == STATE_OPEN, EGameNotOpen);
    assert!(game.sold_tickets < game.total_tickets, ECannotCancelSoldOutGame);
    assert!(ctx.sender() == game.creator, EOnlyCreatorCanCancel);
    assert_sender_matches_character(creator_character, ctx);
    assert!(
        character::id(creator_character) == game.creator_character_id,
        ECreatorCharacterMismatch,
    );
    assert_storage_unit_matches(game, storage_unit_obj);

    let refunded_amount = refund_all_buyers(game, ctx);
    let prize = take_prize(game);

    storage_unit::deposit_to_owned<SweepstakesAuth>(
        storage_unit_obj,
        creator_character,
        prize,
        SweepstakesAuth {},
        ctx,
    );

    game.state = STATE_CANCELED;

    event::emit(GameCanceledEvent {
        game_id: object::id(game),
        creator: game.creator,
        refunded_amount,
    });

    creator_character_owner_cap
}

public fun title(game: &LotteryGame): &String {
    &game.title
}

public fun storage_unit_id(game: &LotteryGame): ID {
    game.storage_unit_id
}

public fun creator(game: &LotteryGame): address {
    game.creator
}

public fun creator_character_id(game: &LotteryGame): ID {
    game.creator_character_id
}

public fun state(game: &LotteryGame): u8 {
    game.state
}

public fun ticket_price(game: &LotteryGame): u64 {
    game.ticket_price
}

public fun total_tickets(game: &LotteryGame): u64 {
    game.total_tickets
}

public fun sold_tickets(game: &LotteryGame): u64 {
    game.sold_tickets
}

public fun prize_type_id(game: &LotteryGame): u64 {
    game.prize_type_id
}

public fun prize_quantity(game: &LotteryGame): u32 {
    game.prize_quantity
}

public fun prize_locked(game: &LotteryGame): bool {
    option::is_some(&game.prize)
}

public fun sale_proceeds_value(game: &LotteryGame): u64 {
    balance::value(&game.sale_proceeds)
}

public fun winning_ticket(game: &LotteryGame): &Option<u64> {
    &game.winning_ticket
}

public fun winner(game: &LotteryGame): &Option<WinnerSnapshot> {
    &game.winner
}

public fun purchases(game: &LotteryGame): &vector<TicketPurchase> {
    &game.purchases
}

public fun ticket_receipt(game: &LotteryGame, ticket_number: u64): TicketReceipt {
    ticket_receipt_internal(game, ticket_number)
}

fun assert_sender_matches_character(character_obj: &Character, ctx: &TxContext) {
    assert!(
        character::character_address(character_obj) == ctx.sender(),
        ECharacterSenderMismatch,
    );
}

fun assert_storage_unit_matches(game: &LotteryGame, storage_unit_obj: &StorageUnit) {
    assert!(game.storage_unit_id == object::id(storage_unit_obj), EStorageUnitMismatch);
}

fun ticket_receipt_internal(game: &LotteryGame, ticket_number: u64): TicketReceipt {
    assert!(ticket_number < game.sold_tickets, ETicketRecordNotFound);
    assert!(df::exists_(&game.id, ticket_number), ETicketRecordNotFound);
    *df::borrow<u64, TicketReceipt>(&game.id, ticket_number)
}

fun winner_snapshot(game: &LotteryGame): WinnerSnapshot {
    assert!(option::is_some(&game.winner), EWinnerNotDrawn);
    *option::borrow(&game.winner)
}

fun take_prize(game: &mut LotteryGame): Item {
    assert!(option::is_some(&game.prize), EPrizeAlreadyClaimed);
    option::extract(&mut game.prize)
}

fun issue_tickets(
    game: &mut LotteryGame,
    buyer: address,
    buyer_character_id: ID,
    start_ticket: u64,
    ticket_count: u64,
) {
    let game_id = object::id(game);
    let mut offset = 0;
    while (offset < ticket_count) {
        let ticket_number = start_ticket + offset;
        let ticket_hash = compute_ticket_hash(
            game_id,
            buyer,
            buyer_character_id,
            ticket_number,
        );
        let receipt = TicketReceipt {
            holder: buyer,
            character_id: buyer_character_id,
            ticket_number,
            ticket_hash,
        };
        df::add(&mut game.id, ticket_number, receipt);

        event::emit(TicketIssuedEvent {
            game_id,
            holder: buyer,
            character_id: buyer_character_id,
            ticket_number,
            ticket_hash,
        });
        offset = offset + 1;
    };
}

fun compute_ticket_hash(
    game_id: ID,
    buyer: address,
    buyer_character_id: ID,
    ticket_number: u64,
): vector<u8> {
    let seed = TicketHashSeed {
        game_id,
        buyer,
        character_id: buyer_character_id,
        ticket_number,
    };
    hash::blake2b256(&bcs::to_bytes(&seed))
}

fun pay_creator(game: &mut LotteryGame, ctx: &mut TxContext) {
    let proceeds = balance::value(&game.sale_proceeds);
    if (proceeds > 0) {
        let proceeds_balance = balance::withdraw_all(&mut game.sale_proceeds);
        let proceeds_coin = coin::from_balance(proceeds_balance, ctx);
        transfer::public_transfer(proceeds_coin, game.creator);
    };
}

fun refund_all_buyers(game: &mut LotteryGame, ctx: &mut TxContext): u64 {
    let refunded_total = balance::value(&game.sale_proceeds);
    let len = game.purchases.length();
    let mut index = 0;

    while (index < len) {
        let purchase = *vector::borrow(&game.purchases, index);
        if (purchase.paid_amount > 0) {
            let refund_balance = balance::split(&mut game.sale_proceeds, purchase.paid_amount);
            let refund_coin = coin::from_balance(refund_balance, ctx);
            transfer::public_transfer(refund_coin, purchase.buyer);
        };
        index = index + 1;
    };

    refunded_total
}
