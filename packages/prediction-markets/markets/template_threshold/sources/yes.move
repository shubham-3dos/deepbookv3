/// One-Time Witness for the YES outcome token.
/// Deployed per threshold prediction market (oracle).
module prediction_market_threshold::yes;

use sui::coin_registry;

/// OTW for the YES outcome. Consumed during init to create TreasuryCap.
public struct YES has drop {}

fun init(witness: YES, ctx: &mut TxContext) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6,
        b"YES".to_string(),
        b"Prediction YES".to_string(),
        b"YES outcome token for threshold prediction market".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = builder.finalize(ctx);
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
