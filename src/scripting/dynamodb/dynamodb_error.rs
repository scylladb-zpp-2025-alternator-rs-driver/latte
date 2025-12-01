use rune::alloc::fmt::TryWrite;
use rune::runtime::VmResult;
use rune::{vm_write, Any};
use std::fmt::{Display, Formatter};

#[derive(Any, Debug)]
pub struct DynamoDBError(pub DynamoDBErrorKind);

#[derive(Debug)]
pub enum DynamoDBErrorKind {
    FailedToConnect(String, String),
    QueryRetriesExceeded(String),
    Overloaded(String),
    CustomError(String),
    Error(String),
}

impl DynamoDBError {
    pub fn query_retries_exceeded(retry_number: u64) -> DynamoDBError {
        DynamoDBError(DynamoDBErrorKind::QueryRetriesExceeded(format!(
            "Max retry attempts ({retry_number}) reached"
        )))
    }

    #[rune::function(protocol = STRING_DISPLAY)]
    pub fn string_display(&self, f: &mut rune::runtime::Formatter) -> VmResult<()> {
        vm_write!(f, "{}", self.to_string());
        VmResult::Ok(())
    }
}

impl Display for DynamoDBError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match &self.0 {
            DynamoDBErrorKind::FailedToConnect(addr, e) => {
                write!(f, "Failed to connect to DynamoDB at {}: {}", addr, e)
            }
            DynamoDBErrorKind::QueryRetriesExceeded(s) => write!(f, "QueryRetriesExceeded: {s}"),
            DynamoDBErrorKind::Overloaded(s) => write!(f, "Overloaded: {s}"),
            DynamoDBErrorKind::CustomError(s) => write!(f, "{s}"),
            DynamoDBErrorKind::Error(s) => write!(f, "{s}"),
        }
    }
}

impl std::error::Error for DynamoDBError {}

pub type DbError = DynamoDBError;
pub type DbErrorKind = DynamoDBErrorKind;
