//
//  Item.swift
//  Bolo
//
//  Transcription history record.
//

import Foundation
import SwiftData

@Model
final class Transcription {
    var text: String
    var timestamp: Date
    var providerKind: String
    var model: String
    var wordCount: Int

    init(text: String, providerKind: String, model: String) {
        self.text = text
        self.timestamp = Date()
        self.providerKind = providerKind
        self.model = model
        self.wordCount = text.split(omittingEmptySubsequences: true) { $0.isWhitespace }.count
    }
}
