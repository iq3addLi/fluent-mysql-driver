import Async
import CodableKit
import FluentSQL
import Foundation

/// Adds ability to do basic Fluent queries using a `MySQLDatabase`.
extension MySQLDatabase: QuerySupporting {
    /// See `QuerySupporting.execute`
    public static func execute<D>(
        query: DatabaseQuery<MySQLDatabase>,
        into handler: @escaping (D, MySQLConnection) throws -> (),
        on connection: MySQLConnection
    ) -> EventLoopFuture<Void> where D : Decodable {
        return Future<Void>.flatMap(on: connection) {
            // Convert Fluent `DatabaseQuery` to generic FluentSQL `DataQuery`
            var (sqlQuery, bindValues) = query.makeDataQuery()

            // If the query has an Encodable model attached serialize it.
            // Dictionary keys should be added to the DataQuery as columns.
            // Dictionary values should be added to the parameterized array.
            let modelData: [MySQLDataConvertible]
            if let model = query.data {
                let data = try MySQLRowEncoder().encode(model)
                sqlQuery.columns += data.keys.map { key in
                    return DataColumn(table: key.table ?? query.entity, name: key.name)
                }
                modelData = [MySQLDataConvertible](data.values.map { $0 as MySQLDataConvertible })
            } else {
                modelData = []
            }

            // Create a PostgreSQL-flavored SQL serializer to create a SQL string
            let sqlSerializer = MySQLSerializer()
            let sqlString = sqlSerializer.serialize(data: sqlQuery)

            // Combine the query data with bind values from filters.
            // All bind values must come _after_ the columns section of the query.
            let parameters: [MySQLDataConvertible] = try modelData + bindValues.map { bind in
                let encodable = bind.encodable
                guard let convertible = encodable as? MySQLDataConvertible else {
                    let type = Swift.type(of: encodable)
                    throw MySQLError(
                        identifier: "convertible",
                        reason: "Unsupported encodable type: \(type)",
                        suggestedFixes: [
                            "Conform \(type) to PostgreSQLDataCustomConvertible"
                        ],
                        source: .capture()
                    )
                }
                return convertible
            }

            // Run the query
            return connection.query(sqlString, parameters) { row in
                let decoded = try MySQLRowDecoder().decode(D.self, from: row)
                try handler(decoded, connection)
            }
        }
    }

    /// See `QuerySupporting.modelEvent`
    public static func modelEvent<M>(event: ModelEvent, model: M, on connection: MySQLConnection) -> Future<M>
        where MySQLDatabase == M.Database, M: Model
    {
        switch event {
        case .willCreate:
            if M.ID.self == UUID.self {
                var model = model
                model.fluentID = UUID() as? M.ID
                return Future.map(on: connection) { model }
            }
        case .didCreate:
            if M.ID.self == Int.self {
                return connection.simpleQuery("SELECT LASTVAL();").map(to: M.self) { row in
                    var model = model
                    try model.fluentID = row[0]["lastval"]?.decode(Int.self) as? M.ID
                    return model
                }
            }
        default: break
        }

        return Future.map(on: connection) { model }
    }
}

