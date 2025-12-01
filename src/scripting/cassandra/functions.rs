use super::cass_error::{CassError, CassErrorKind};
use super::context::Context;
use super::cql_types::Uuid;
use rune::runtime::{Mut, Ref};
use rune::{Any, Value};
use std::ops::Deref;

/// Creates a new UUID for current iteration
#[rune::function]
pub fn uuid(i: i64) -> Uuid {
    Uuid::new(i)
}

#[rune::function(instance)]
pub async fn prepare(mut ctx: Mut<Context>, key: Ref<str>, cql: Ref<str>) -> Result<(), CassError> {
    ctx.prepare(&key, &cql).await
}

#[rune::function(instance)]
pub async fn signal_failure(ctx: Ref<Context>, message: Ref<str>) -> Result<(), CassError> {
    ctx.signal_failure(message.deref()).await
}

#[rune::function(instance)]
pub async fn execute(ctx: Ref<Context>, cql: Ref<str>) -> Result<Value, CassError> {
    ctx.execute(cql.deref()).await
}

#[rune::function(instance)]
pub async fn execute_with_validation(
    ctx: Ref<Context>,
    cql: Ref<str>,
    validation_args: Vec<Value>,
) -> Result<Value, CassError> {
    match validation_args.as_slice() {
        // (int): expected_rows
        [Value::Integer(expected_rows)] => {
            ctx.execute_with_validation(
                cql.deref(),
                *expected_rows as u64,
                *expected_rows as u64,
                "",
            )
            .await
        }
        // (int, int): expected_rows_num_min, expected_rows_num_max
        [Value::Integer(min), Value::Integer(max)] => {
            ctx.execute_with_validation(cql.deref(), *min as u64, *max as u64, "")
                .await
        }
        // (int, str): expected_rows, custom_err_msg
        [Value::Integer(expected_rows), Value::String(custom_err_msg)] => {
            ctx.execute_with_validation(
                cql.deref(),
                *expected_rows as u64,
                *expected_rows as u64,
                &custom_err_msg.borrow_ref().unwrap(),
            )
            .await
        }
        // (int, int, str): expected_rows_num_min, expected_rows_num_max, custom_err_msg
        [Value::Integer(min), Value::Integer(max), Value::String(custom_err_msg)] => {
            ctx.execute_with_validation(
                cql.deref(),
                *min as u64,
                *max as u64,
                &custom_err_msg.borrow_ref().unwrap(),
            )
            .await
        }
        _ => Err(CassError(CassErrorKind::Error(
            "Invalid arguments for execute_with_validation".to_string(),
        ))),
    }
}

#[rune::function(instance)]
pub async fn execute_with_result(ctx: Ref<Context>, cql: Ref<str>) -> Result<Value, CassError> {
    ctx.execute_with_result(cql.deref()).await
}

#[rune::function(instance)]
pub async fn execute_prepared(
    ctx: Ref<Context>,
    key: Ref<str>,
    params: Value,
) -> Result<Value, CassError> {
    ctx.execute_prepared(&key, params).await
}

#[rune::function(instance)]
pub async fn execute_prepared_with_validation(
    ctx: Ref<Context>,
    key: Ref<str>,
    params: Value,
    validation_args: Vec<Value>,
) -> Result<Value, CassError> {
    match validation_args.as_slice() {
        // (int): expected_rows
        [Value::Integer(expected_rows)] => {
            ctx.execute_prepared_with_validation(
                &key,
                params,
                *expected_rows as u64,
                *expected_rows as u64,
                "",
            )
            .await
        }
        // (int, int): expected_rows_num_min, expected_rows_num_max
        [Value::Integer(min), Value::Integer(max)] => {
            ctx.execute_prepared_with_validation(&key, params, *min as u64, *max as u64, "")
                .await
        }
        // (int, str): expected_rows, custom_err_msg
        [Value::Integer(expected_rows), Value::String(custom_err_msg)] => {
            ctx.execute_prepared_with_validation(
                &key,
                params,
                *expected_rows as u64,
                *expected_rows as u64,
                &custom_err_msg.borrow_ref().unwrap(),
            )
            .await
        }
        // (int, int, str): expected_rows_num_min, expected_rows_num_max, custom_err_msg
        [Value::Integer(min), Value::Integer(max), Value::String(custom_err_msg)] => {
            ctx.execute_prepared_with_validation(
                &key,
                params,
                *min as u64,
                *max as u64,
                &custom_err_msg.borrow_ref().unwrap(),
            )
            .await
        }
        _ => Err(CassError(CassErrorKind::Error(
            "Invalid arguments for execute_prepared_with_validation".to_string(),
        ))),
    }
}

#[rune::function(instance)]
pub async fn execute_prepared_with_result(
    ctx: Ref<Context>,
    key: Ref<str>,
    params: Value,
) -> Result<Value, CassError> {
    ctx.execute_prepared_with_result(&key, params).await
}

#[rune::function(instance)]
pub async fn batch_prepared(
    ctx: Ref<Context>,
    keys: Vec<Ref<str>>,
    params: Vec<Value>,
) -> Result<(), CassError> {
    ctx.batch_prepared(keys.iter().map(|k| k.deref()).collect(), params)
        .await
}

#[rune::function(instance)]
pub async fn init_partition_row_distribution_preset(
    mut ctx: Mut<Context>,
    preset_name: Ref<str>,
    row_count: u64,
    rows_per_partitions_base: u64,
    rows_per_partitions_groups: Ref<str>,
) -> Result<(), CassError> {
    ctx.init_partition_row_distribution_preset(
        &preset_name,
        row_count,
        rows_per_partitions_base,
        &rows_per_partitions_groups,
    )
    .await
}

/// This 'Partition' data type is exposed to rune scripts
#[derive(Any)]
pub struct Partition {
    #[rune(get, set, copy, add_assign, sub_assign)]
    idx: u64,

    #[rune(get, copy)]
    rows_num: u64,
}

#[rune::function(instance)]
pub async fn get_partition_info(ctx: Ref<Context>, preset_name: Ref<str>, idx: u64) -> Partition {
    let (idx, rows_num) = ctx
        .get_partition_info(&preset_name, idx)
        .await
        .expect("failed to get partition");
    Partition { idx, rows_num }
}

#[rune::function(instance)]
pub async fn get_partition_idx(ctx: Ref<Context>, preset_name: Ref<str>, idx: u64) -> u64 {
    let (idx, _rows_num) = ctx
        .get_partition_info(&preset_name, idx)
        .await
        .expect("failed to get partition");
    idx
}

#[rune::function(instance)]
pub async fn get_datacenters(ctx: Ref<Context>) -> Result<Vec<String>, CassError> {
    ctx.get_datacenters().await
}

#[rune::function(instance)]
pub fn elapsed_secs(ctx: &Context) -> f64 {
    ctx.elapsed_secs()
}
