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

import Foundation

public enum RowError: Error {
  case expectedField(DeclaredField)
  case unexpectedNilValue(DeclaredField)
}

public struct RowIterator {
  public typealias Element = Row
  
  let block: () -> Element?
  var index: Int = 0
  
  init(block: @escaping () -> Element?) {
    self.block = block
  }
  
  public func next() -> Element? {
    return block()
  }
}

public struct Row: CustomStringConvertible {
  public var dataByfield: [String: Data?]
    
  public var fields: [String] {
    return Array(dataByfield.keys)
  }
  
  public init(dataByfield: [String: Data?]) {
    self.dataByfield = dataByfield
  }

  public func data(_ field: DeclaredField) throws -> Data? {
    /*
     Supplying a fielName can done either
     1. Qualified, e.g. 'users.id'
     2. Non-qualified e.g. 'id'
         
     A statement will cast qualified fields from 'users.id' to 'users__id'
         
     Because of this, a given field name must be checked for three type of keys
    */
    
    let fieldCandidates = [
      field.unqualifiedName,
      field.alias,
      field.qualifiedName
    ]
        
    for fieldNameCandidate in fieldCandidates {
      // Return the first value we find by key, even if it's nil.
      
      if dataByfield.index(forKey: fieldNameCandidate) != nil {
        return dataByfield[fieldNameCandidate]!
      }
    }
    
    throw RowError.expectedField(field)
  }
    
  public func data(_ field: DeclaredField) throws -> Data {
    guard let data: Data = try data(field) else {
      throw RowError.unexpectedNilValue(field)
    }
        
    return data
  }
    
  public func data(_ field: String) throws -> Data {
    let field = DeclaredField(name: field)
    
    guard let data: Data = try data(field) else {
      throw RowError.unexpectedNilValue(field)
    }
        
    return data
  }
    
  public func value<T: SQLDataConvertible>(_ field: DeclaredField) throws -> T? {
    guard let data: Data = try data(field) else {
      return nil
    }
        
    return try T(rawSQLData: data)
  }
    
  public func value<T: SQLDataConvertible>(_ field: DeclaredField) throws -> T {
    guard let data: Data = try data(field) else {
      throw RowError.unexpectedNilValue(field)
    }
        
    return try T(rawSQLData: data)
  }
    
  public func data(field: String) throws -> Data? {
    return try data(DeclaredField(name: field))
  }
    
  public func value<T: SQLDataConvertible>(_ field: String) throws -> T? {
    return try value(DeclaredField(name: field))
  }
    
  public func value<T: SQLDataConvertible>(_ field: String) throws -> T {
    return try value(DeclaredField(name: field))
  }
    
  public var description: String {        
    return dataByfield.map { key, value in
      guard let value = value else {
        return "NULL"
      }
            
      return "\(key): \(value)"
    }.joined(separator: ", ")
  }
}
