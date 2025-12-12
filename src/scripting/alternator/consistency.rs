use clap::{builder::PossibleValue, ValueEnum};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Default, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Consistency {
    #[default]
    Eventual,
    Strong,
}

impl Consistency {
    pub fn consistency(&self) -> aws_sdk_dynamodb::types::MultiRegionConsistency {
        match self {
            Self::Eventual => aws_sdk_dynamodb::types::MultiRegionConsistency::Eventual,
            Self::Strong => aws_sdk_dynamodb::types::MultiRegionConsistency::Strong,
        }
    }
}

impl ValueEnum for Consistency {
    fn value_variants<'a>() -> &'a [Self] {
        &[Self::Eventual, Self::Strong]
    }

    fn from_str(s: &str, _ignore_case: bool) -> Result<Self, String> {
        match s.to_lowercase().as_str() {
            "eventual" => Ok(Self::Eventual),
            "strong" => Ok(Self::Strong),
            s => Err(format!("Unknown consistency level {s}")),
        }
    }

    fn to_possible_value(&self) -> Option<PossibleValue> {
        match self {
            Self::Eventual => Some(PossibleValue::new("EVENTUAL")),
            Self::Strong => Some(PossibleValue::new("STRONG")),
        }
    }
}
