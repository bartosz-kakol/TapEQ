//
//  Item.swift
//  TapEQ
//
//  Created by Bartosz Kąkol on 25/11/2026.
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
