import gleam/list
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

/// Validates that an output schema is available and within the modern MCP profile.
pub fn validate_output_schema(
  schema_res: Result(Schema, SchemaError),
) -> Result(Schema, SchemaAdmissionError) {
  case schema_res {
    Error(_) -> Error(MissingSchema)
    Ok(schema) ->
      case materialize_schema(schema) {
        value.Object(_) -> Ok(schema)
        _ -> Error(SchemaMustBeObject(schema_type_name(schema)))
      }
  }
}

/// Checks if a schema represents an object-like structure. Fails closed: the
/// any schema, and a kind this package does not know, is accepted only when
/// its document declares `"type": "object"`.
pub fn is_object_schema(schema: Schema) -> Bool {
  case codec.view(schema) {
    codec.ObjectSchema(_) -> True
    codec.UnionSchema(_) -> True
    codec.OtherSchema(document) -> document_declares_object(document)
    codec.AnySchema -> False
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.IntegerRangeSchema(_, _)
    | codec.NumberSchema
    | codec.NumberRangeSchema(_, _)
    | codec.BoolSchema
    | codec.PairSchema(_, _)
    | codec.ListSchema(_)
    | codec.NullableSchema(_) -> False
  }
}

fn document_declares_object(document: Value) -> Bool {
  case document {
    value.Object(entries) ->
      list.any(entries, fn(entry) { entry == #("type", value.String("object")) })
    _ -> False
  }
}

pub fn schema_type_name(schema: Schema) -> String {
  case codec.view(schema) {
    codec.StringSchema -> "string"
    codec.StringEnumSchema(_) -> "string_enum"
    codec.IntSchema -> "integer"
    codec.NumberSchema -> "number"
    codec.BoolSchema -> "boolean"
    codec.PairSchema(_, _) -> "pair"
    codec.ListSchema(_) -> "list"
    codec.NullableSchema(_) -> "nullable"
    codec.ObjectSchema(_) -> "object"
    codec.UnionSchema(_) -> "union"
    codec.IntegerRangeSchema(_, _) -> "integer_range"
    codec.NumberRangeSchema(_, _) -> "number_range"
    codec.AnySchema -> "any"
    codec.OtherSchema(_) -> "other"
  }
}

/// Materializes a Blueprint Schema into a JSON Schema Draft 2020-12 Value.
pub fn materialize_schema(schema: Schema) -> Value {
  codec.schema_document(schema)
}
