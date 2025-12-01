use super::dynamodb_error::{DynamoDBError, DynamoDBErrorKind};
use crate::config::{RetryInterval, ValidationStrategy};
use crate::error::LatteError;
use crate::scripting::common::ClusterInfo;
use crate::stats::session::SessionStats;
use aws_sdk_dynamodb::Client;
use rune::Any;
use std::time::Instant;
use try_lock::TryLock;

#[derive(Any)]
pub struct Context {
    client: Option<Client>,
    pub stats: TryLock<SessionStats>,
    start_time: TryLock<Instant>,
    pub retry_number: u64,
    pub retry_interval: RetryInterval,
    pub validation_strategy: ValidationStrategy,
    #[rune(get, set, add_assign, copy)]
    pub load_cycle_count: u64,
}

unsafe impl Send for Context {}
unsafe impl Sync for Context {}

impl Context {
    pub fn new(
        client: Option<Client>,
        retry_number: u64,
        retry_interval: RetryInterval,
        validation_strategy: ValidationStrategy,
    ) -> Context {
        Context {
            client,
            stats: TryLock::new(SessionStats::new()),
            start_time: TryLock::new(Instant::now()),
            retry_number,
            retry_interval,
            validation_strategy,
            load_cycle_count: 0,
        }
    }

    pub fn clone(&self) -> Result<Self, LatteError> {
        Ok(Context {
            client: self.client.clone(),
            stats: TryLock::new(SessionStats::default()),
            start_time: TryLock::new(Instant::now()),
            retry_number: self.retry_number,
            retry_interval: self.retry_interval,
            validation_strategy: self.validation_strategy,
            load_cycle_count: self.load_cycle_count,
        })
    }

    pub async fn cluster_info(&self) -> Result<Option<ClusterInfo>, DynamoDBError> {
        Ok(Some(ClusterInfo {
            name: "DynamoDB".to_string(),
            db_version: "DynamoDB".to_string(),
        }))
    }

    pub async fn signal_failure(&self, message: &str) -> Result<(), DynamoDBError> {
        let err = DynamoDBError(DynamoDBErrorKind::CustomError(message.to_string()));
        Err(err)
    }

    pub fn elapsed_secs(&self) -> f64 {
        self.start_time.try_lock().unwrap().elapsed().as_secs_f64()
    }

    pub fn take_session_stats(&self) -> SessionStats {
        let mut stats = self.stats.try_lock().unwrap();
        let result = stats.clone();
        stats.reset();
        result
    }

    pub fn reset(&self) {
        self.stats.try_lock().unwrap().reset();
        *self.start_time.try_lock().unwrap() = Instant::now();
    }
}
