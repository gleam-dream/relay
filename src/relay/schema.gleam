import json/blueprint/codec.{type Schema, type SchemaError}
import json/blueprint/value.{type Value}

pub type SchemaAdmissionError {
  MissingSchema
  SchemaMustBeObject(String)
}

/// Validates that an input schema has an object root required by MCP tool arguments.
pub fn validate_input_schema(
  schema_res: Result(Schema, SchemaError),
) -> Result(Schema, SchemaAdmissionError) {
  case schema_res {
    Error(_) -> Error(MissingSchema)
    Ok(schema) ->
      case is_object_schema(schema) {
        True -> Ok(schema)
        False -> Error(SchemaMustBeObject(schema_type_name(schema)))
      }
  }
}

/// Checks if a schema represents an object-like structure.
pub fn is_object_schema(schema: Schema) -> Bool {
  case schema {
    codec.ObjectSchema(_) -> True
    codec.FieldSchema(_, _) -> True
    codec.TaggedSchema(_, _, _, _) -> True
    _ -> False
  }
}

pub fn schema_type_name(schema: Schema) -> String {
  case schema {
    codec.StringSchema -> "string"
    codec.StringEnumSchema(_) -> "string_enum"
    codec.IntSchema -> "integer"
    codec.NumberSchema -> "number"
    codec.BoolSchema -> "boolean"
    codec.PairSchema(_, _) -> "pair"
    codec.FieldSchema(_, _) -> "field"
    codec.ListSchema(_) -> "list"
    codec.NullableSchema(_) -> "nullable"
    codec.ObjectSchema(_) -> "object"
    codec.TaggedSchema(_, _, _, _) -> "tagged"
    codec.IntegerRangeSchema(_, _) -> "integer_range"
    codec.NumberRangeSchema(_, _) -> "number_range"
  }
}

/// Materializes a Blueprint Schema into a JSON Schema Draft 2020-12 Value.
pub fn materialize_schema(schema: Schema) -> Value {
  codec.schema_document(schema)
}
