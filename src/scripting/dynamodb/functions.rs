use super::context::Context;
use super::dynamodb_error::DynamoDBError;
use rune::runtime::Ref;
use std::ops::Deref;

#[rune::function(instance)]
pub async fn signal_failure(ctx: Ref<Context>, message: Ref<str>) -> Result<(), DynamoDBError> {
    ctx.signal_failure(message.deref()).await
}

#[rune::function(instance)]
pub fn elapsed_secs(ctx: Ref<Context>) -> f64 {
    ctx.elapsed_secs()
}
