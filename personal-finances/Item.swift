//
//  Item.swift
//  personal-finances
//
//  Created by Mihir Sangameswar on 8/29/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
