use rune::{ContextError, Module};
use rust_embed::RustEmbed;
use std::collections::HashMap;

pub mod common;
mod functions_common;

#[cfg(feature = "cassandra")]
mod cassandra;
#[cfg(feature = "dynamodb")]
mod dynamodb;

#[cfg(feature = "cassandra")]
pub use cassandra::cass_error as db_error;
#[cfg(feature = "cassandra")]
pub use cassandra::connect;
#[cfg(feature = "cassandra")]
pub use cassandra::context;

#[cfg(feature = "dynamodb")]
pub use dynamodb::connect;
#[cfg(feature = "dynamodb")]
pub use dynamodb::context;
#[cfg(feature = "dynamodb")]
pub use dynamodb::dynamodb_error as db_error;

#[derive(RustEmbed)]
#[folder = "resources/"]
struct Resources;

pub fn install(rune_ctx: &mut rune::Context, params: HashMap<String, String>) {
    try_install(rune_ctx, params).unwrap()
}

#[cfg(feature = "cassandra")]
fn try_install(
    rune_ctx: &mut rune::Context,
    params: HashMap<String, String>,
) -> Result<(), ContextError> {
    use cassandra::cass_error::CassError;
    use cassandra::context::Context;
    use cassandra::cql_types;
    use cassandra::functions;

    let mut context_module = Module::default();
    context_module.ty::<Context>()?;
    context_module.function_meta(functions::prepare)?;
    context_module.function_meta(functions::signal_failure)?;

    // NOTE: 1st group of query-oriented functions - without usage of prepared statements
    context_module.function_meta(functions::execute)?;
    context_module.function_meta(functions::execute_with_validation)?;
    context_module.function_meta(functions::execute_with_result)?;
    // NOTE: 2nd group of query-oriented functions - with usage of prepared statements
    context_module.function_meta(functions::execute_prepared)?;
    context_module.function_meta(functions::execute_prepared_with_validation)?;
    context_module.function_meta(functions::execute_prepared_with_result)?;

    context_module.function_meta(functions::batch_prepared)?;
    context_module.function_meta(functions::init_partition_row_distribution_preset)?;
    context_module.function_meta(functions::get_partition_idx)?;
    context_module.ty::<functions::Partition>()?;
    context_module.function_meta(functions::get_partition_info)?;
    context_module.function_meta(functions::get_datacenters)?;
    context_module.function_meta(functions::elapsed_secs)?;

    let mut err_module = Module::default();
    err_module.ty::<CassError>()?;
    err_module.function_meta(CassError::string_display)?;

    let mut uuid_module = Module::default();
    uuid_module.ty::<cql_types::Uuid>()?;
    uuid_module.function_meta(cql_types::Uuid::string_display)?;

    let mut latte_module = Module::with_crate("latte")?;
    install_common_functions(&mut latte_module, params)?;
    latte_module.function_meta(functions::uuid)?;

    latte_module.function_meta(cql_types::i64::to_i32)?;
    latte_module.function_meta(cql_types::i64::to_i16)?;
    latte_module.function_meta(cql_types::i64::to_i8)?;
    latte_module.function_meta(cql_types::i64::to_f32)?;
    latte_module.function_meta(cql_types::i64::clamp)?;

    latte_module.function_meta(cql_types::f64::to_i8)?;
    latte_module.function_meta(cql_types::f64::to_i16)?;
    latte_module.function_meta(cql_types::f64::to_i32)?;
    latte_module.function_meta(cql_types::f64::to_f32)?;
    latte_module.function_meta(cql_types::f64::clamp)?;

    let mut fs_module = Module::with_crate("fs")?;
    install_fs_functions(&mut fs_module)?;

    rune_ctx.install(&context_module)?;
    rune_ctx.install(&err_module)?;
    rune_ctx.install(&uuid_module)?;
    rune_ctx.install(&latte_module)?;
    rune_ctx.install(&fs_module)?;

    Ok(())
}

#[cfg(feature = "dynamodb")]
fn try_install(
    rune_ctx: &mut rune::Context,
    params: HashMap<String, String>,
) -> Result<(), ContextError> {
    use dynamodb::context::Context;
    use dynamodb::dynamodb_error::DynamoDBError;
    use dynamodb::functions;

    let mut context_module = Module::default();
    context_module.ty::<Context>()?;
    context_module.function_meta(functions::signal_failure)?;
    context_module.function_meta(functions::elapsed_secs)?;

    let mut err_module = Module::default();
    err_module.ty::<DynamoDBError>()?;
    err_module.function_meta(DynamoDBError::string_display)?;

    let mut latte_module = Module::with_crate("latte")?;
    install_common_functions(&mut latte_module, params)?;

    let mut fs_module = Module::with_crate("fs")?;
    install_fs_functions(&mut fs_module)?;

    rune_ctx.install(&context_module)?;
    rune_ctx.install(&err_module)?;
    rune_ctx.install(&latte_module)?;
    rune_ctx.install(&fs_module)?;

    Ok(())
}

fn install_common_functions(
    latte_module: &mut Module,
    params: HashMap<String, String>,
) -> Result<(), ContextError> {
    latte_module.macro_("param", move |ctx, ts| {
        functions_common::param(ctx, &params, ts)
    })?;
    latte_module.function_meta(functions_common::blob)?;
    latte_module.function_meta(functions_common::text)?;
    latte_module.function_meta(functions_common::vector)?;
    latte_module.function_meta(functions_common::join)?;
    latte_module.function_meta(functions_common::now_timestamp)?;
    latte_module.function_meta(functions_common::hash)?;
    latte_module.function_meta(functions_common::hash2)?;
    latte_module.function_meta(functions_common::hash_range)?;
    latte_module.function_meta(functions_common::hash_select)?;
    latte_module.function_meta(functions_common::normal)?;
    latte_module.function_meta(functions_common::normal_f32)?;
    latte_module.function_meta(functions_common::uniform)?;
    latte_module.function_meta(functions_common::is_none)?;
    Ok(())
}

fn install_fs_functions(fs_module: &mut Module) -> Result<(), ContextError> {
    fs_module.function_meta(functions_common::read_to_string)?;
    fs_module.function_meta(functions_common::read_lines)?;
    fs_module.function_meta(functions_common::read_words)?;
    fs_module.function_meta(functions_common::read_resource_to_string)?;
    fs_module.function_meta(functions_common::read_resource_lines)?;
    fs_module.function_meta(functions_common::read_resource_words)?;
    Ok(())
}
