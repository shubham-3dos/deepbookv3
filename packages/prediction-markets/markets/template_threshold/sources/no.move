/// One-Time Witness for the NO outcome token.
/// Deployed per threshold prediction market (oracle).
module prediction_market_threshold::no;

use sui::coin_registry;

/// OTW for the NO outcome. Consumed during init to create TreasuryCap.
public struct NO has drop {}

fun init(witness: NO, ctx: &mut TxContext) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6,
        b"NO".to_string(),
        b"Prediction NO".to_string(),
        b"NO outcome token for threshold prediction market".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = builder.finalize(ctx);
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
