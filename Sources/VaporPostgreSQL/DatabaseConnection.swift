// The MIT License (MIT)
//
// Copyright (c) 2015 Formbound
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import CPostgreSQL
import Foundation

public struct ConnectionError: Error, CustomStringConvertible {
  public let description: String
}

public class DatabaseConnection {
  public struct Configuration {
    public let host: String
    public let port: Int
    public let database: String
    public let username: String?
    public let password: String?
    public let options: String?
    public let tty: String?
    
    public init(host: String, port: Int = 5432, database: String, username: String? = nil, password: String? = nil, options: String? = nil, tty: String? = nil) {
      self.host = host
      self.port = port
      self.database = database
      self.username = username
      self.password = password
      self.options = options
      self.tty = tty
    }
  }

  public static let willExecuteSQL = Notification.Name("PostgreSQL.Connection.willExecuteSQL") // object = "<sql>"
  
  public enum InternalStatus {
    case bad
    case started
    case made
    case awaitingResponse
    case authOK
    case settingEnvironment
    case sslStartup
    case ok
    case unknown
    case needed
        
    public init(status: ConnStatusType) {
      switch status {
        case CONNECTION_NEEDED:
          self = .needed
        case CONNECTION_OK:
          self = .ok
        case CONNECTION_STARTED:
          self = .started
        case CONNECTION_MADE:
          self = .made
        case CONNECTION_AWAITING_RESPONSE:
          self = .awaitingResponse
        case CONNECTION_AUTH_OK:
          self = .authOK
        case CONNECTION_SSL_STARTUP:
          self = .sslStartup
        case CONNECTION_SETENV:
          self = .settingEnvironment
        case CONNECTION_BAD:
          self = .bad
        default:
          self = .unknown
      }
    }
  }

  public let configuration: Configuration

  public var mostRecentError: ConnectionError? {
    guard let errorString = String(validatingUTF8: PQerrorMessage(self.connection)), !errorString.isEmpty else {
      return nil
    }
    
    return ConnectionError(description: errorString)
  }

  public var internalStatus: InternalStatus {
    return InternalStatus(status: PQstatus(self.connection))
  }
  
  fileprivate var connection: OpaquePointer?

  public required init(configuration: Configuration) {
    self.configuration = configuration
  }
    
  deinit {
    close()
  }
    
  public func open() throws {
    self.connection = PQsetdbLogin(
      self.configuration.host,
      String(self.configuration.port),
      self.configuration.options ?? "",
      self.configuration.tty ?? "",
      self.configuration.database,
      self.configuration.username ?? "",
      self.configuration.password ?? ""
    )
        
    if let error = mostRecentError {
      throw error
    }
  }
    
  public func close() {
    PQfinish(self.connection)
    self.connection = nil
  }
    
  @discardableResult
  public func executeInsertQuery<T: SQLDataConvertible>(query: InsertQuery, returningPrimaryKeyForField primaryKey: DeclaredField) throws -> T {

    let components = query.queryComponents.appending(QueryComponents(strings: ["RETURNING", primaryKey.qualifiedName, "AS", "returned__pk"]))

    DispatchQueue.global(qos: .background).async() {
      NotificationCenter.default.post(name: DatabaseConnection.willExecuteSQL, object: components.string, userInfo: nil)
    }
    
    let result = try execute(components)
        
    guard let pk: T = try result.first?.value("returned__pk") else {
      throw ConnectionError(description: "Did not receive returned primary key")
    }
        
    return pk
  }
    
  @discardableResult
  public func execute(_ components: QueryComponents) throws -> Result {
#if Xcode
    DispatchQueue.global(qos: .background).async() {
      NotificationCenter.default.post(name: DatabaseConnection.willExecuteSQL, object: components.string, userInfo: nil)
    }
#endif

    guard !components.values.isEmpty else {
      guard let resultPointer = PQexec(self.connection, components.string) else {
        throw mostRecentError ?? ConnectionError(description: "Empty result")
      }
          
      return try Result(resultPointer)
    }

    var parameterData: [UnsafePointer<Int8>?] = []
    var deallocators = [() -> Void]()
    defer { deallocators.forEach { $0() } }

    for parameter in components.values {
      guard let value = parameter else {
        parameterData.append(nil)
        continue
      }
        
      let data: AnyCollection<Int8>
        
      switch value {
        case .binary(let value):
          data = AnyCollection(value.map { Int8($0) })
        case .text(let string):
          data = AnyCollection(string.utf8CString)
      }
              
      let pointer = UnsafeMutablePointer<Int8>.allocate(capacity: Int(data.count))
  
      deallocators.append {
        pointer.deallocate(capacity: Int(data.count))
      }
              
      for (index, byte) in data.enumerated() {
        pointer[index] = byte
      }
          
      parameterData.append(pointer)
    }

    let result: OpaquePointer = try parameterData.withUnsafeBufferPointer { buffer in
      guard let result = PQexecParams(
        self.connection,
        try components.stringWithEscapedValuesUsingPrefix("$") { index, _ in
          return String(index + 1)
        },
        Int32(components.values.count),
        nil,
        buffer.isEmpty ? nil : buffer.baseAddress,
        nil,
        nil,
        0
      ) else {
        throw mostRecentError ?? ConnectionError(description: "Empty result")
      }
        
      return result
    }
      
    return try Result(result)
  }

  @discardableResult
  public func execute(_ statement: String, parameters: [SQLDataConvertible?] = []) throws -> Result {
    return try execute(QueryComponents(statement, values: parameters.map { $0?.sqlData }))
  }
  
  @discardableResult
  public func execute(_ statement: String, parameters: SQLDataConvertible?...) throws -> Result {
    return try execute(statement, parameters: parameters)
  }
  
  @discardableResult
  public func execute(_ convertible: QueryComponentsConvertible) throws -> Result {
    return try execute(convertible.queryComponents)
  }
  
  public func transaction<T>(block: () throws -> T) throws -> T {
    try begin()
    
    do {
      let value = try block()
      try commit()
      return value
    }
    catch {
      try rollback()
      throw error
    }
  }

  @discardableResult
  public func begin() throws -> Result {
    return try execute("BEGIN")
  }
  
  @discardableResult
  public func commit() throws -> Result {
    return try execute("COMMIT")
  }
  
  @discardableResult
  public func rollback() throws -> Result {
    return try execute("ROLLBACK")
  }

  @discardableResult
  public func createSavePointNamed(_ name: String) throws -> Result {
    return try execute("SAVEPOINT \(name)")
  }
    
  @discardableResult
  public func rollbackToSavePointNamed(_ name: String) throws -> Result {
    return try execute("ROLLBACK TO SAVEPOINT \(name)")
  }
    
  @discardableResult
  public func releaseSavePointNamed(_ name: String) throws -> Result {
    return try execute("RELEASE SAVEPOINT \(name)")
  }
  
  public func withSavePointNamed(_ name: String, block: () throws -> Void) throws {
    try createSavePointNamed(name)
    
    do {
      try block()
      try releaseSavePointNamed(name)
    }
    catch {
      try rollbackToSavePointNamed(name)
      try releaseSavePointNamed(name)
      throw error
    }
  }
}
