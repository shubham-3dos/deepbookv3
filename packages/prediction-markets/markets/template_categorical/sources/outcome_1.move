/// One-Time Witness for outcome 1 token.
module prediction_market_categorical::outcome_1;

use sui::coin_registry;

public struct OUTCOME_1 has drop {}

fun init(witness: OUTCOME_1, ctx: &mut TxContext) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6,
        b"OUT_1".to_string(),
        b"Prediction Outcome 1".to_string(),
        b"Outcome 1 token for categorical prediction market".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = builder.finalize(ctx);
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
