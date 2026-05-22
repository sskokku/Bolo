//
//  UsageStats.swift
//  Bolo
//
//  Cumulative usage metrics — persists across history clears so the
//  lifetime word count survives even if you wipe transcription records.
//

import Foundation
import Observation

@Observable
final class UsageStats {
    static let shared = UsageStats()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let totalWords = "totalWordsSpoken"
        static let totalDictations = "totalDictations"
    }

    var totalWords: Int {
        didSet { defaults.set(totalWords, forKey: Keys.totalWords) }
    }

    var totalDictations: Int {
        didSet { defaults.set(totalDictations, forKey: Keys.totalDictations) }
    }

    private init() {
        self.totalWords = defaults.integer(forKey: Keys.totalWords)
        self.totalDictations = defaults.integer(forKey: Keys.totalDictations)
    }

    func record(wordCount: Int) {
        totalWords += wordCount
        totalDictations += 1
    }
}
