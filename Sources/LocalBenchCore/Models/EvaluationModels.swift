import Foundation

/// Human / frontier-model review records (spec §6).
///
/// Evaluations are deliberately separate from metrics: a rating never changes
/// a measured number, and a blind comparison stores which side won without
/// letting the UI leak model identity during the decision.
public enum EvaluationKind: String, Codable, Sendable, CaseIterable, Hashable {
    case thumbs
    case rubric
    case pairwise
}

public struct RubricCriterion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var guidance: String
    public var maximumScore: Int

    public init(id: String = UUID().uuidString, name: String, guidance: String, maximumScore: Int = 4) {
        self.id = id
        self.name = name
        self.guidance = guidance
        self.maximumScore = max(1, maximumScore)
    }
}

public struct RubricScore: Codable, Sendable, Hashable {
    public var criterionID: String
    public var score: Int

    public init(criterionID: String, score: Int) {
        self.criterionID = criterionID
        self.score = score
    }
}

/// A versioned rubric. Version + title are persisted with every score so an
/// old review remains interpretable after the rubric evolves.
public struct EvaluationRubric: Codable, Sendable, Hashable {
    public var version: Int
    public var title: String
    public var criteria: [RubricCriterion]

    public init(version: Int, title: String, criteria: [RubricCriterion]) {
        self.version = version
        self.title = title
        self.criteria = criteria
    }

    public func criterion(id: String) -> RubricCriterion? {
        criteria.first { $0.id == id }
    }

    /// Built-in rubric used by the review UI (versioned, never edited in place).
    public static let v1 = EvaluationRubric(
        version: 1,
        title: "LocalBench response quality v1",
        criteria: [
            RubricCriterion(name: "Correctness", guidance: "Factually correct; no invented claims.", maximumScore: 4),
            RubricCriterion(name: "Grounding", guidance: "Claims trace back to the supplied passages or image.", maximumScore: 4),
            RubricCriterion(name: "Clarity", guidance: "Direct, well-organized, and easy to follow.", maximumScore: 4),
            RubricCriterion(name: "Concision", guidance: "Answers the question without padding.", maximumScore: 4),
        ]
    )
}

/// One review of one backend response.
public struct Evaluation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var requestID: String
    public var backend: BackendID
    public var kind: EvaluationKind
    /// -1 / 0 / +1, or nil when this is a rubric-only review.
    public var thumbs: Int?
    public var rubricVersion: Int?
    public var rubricTitle: String?
    public var scores: [RubricScore]
    public var notes: String
    public var judgedBy: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                requestID: String,
                backend: BackendID,
                kind: EvaluationKind = .rubric,
                thumbs: Int? = nil,
                rubricVersion: Int? = nil,
                rubricTitle: String? = nil,
                scores: [RubricScore] = [],
                notes: String = "",
                judgedBy: String = "local reviewer",
                createdAt: Date = Date()) {
        self.id = id
        self.requestID = requestID
        self.backend = backend
        self.kind = kind
        self.thumbs = thumbs
        self.rubricVersion = rubricVersion
        self.rubricTitle = rubricTitle
        self.scores = scores
        self.notes = notes
        self.judgedBy = judgedBy
        self.createdAt = createdAt
    }

    public var totalScore: Int { scores.reduce(0) { $0 + $1.score } }
    public var maximumScore: Int {
        guard let version = rubricVersion else { return 0 }
        let rubric = version == EvaluationRubric.v1.version ? EvaluationRubric.v1 : nil
        return rubric?.criteria.reduce(0) { $0 + $1.maximumScore } ?? 0
    }
}

/// A pairwise preference between two backend responses (optionally blind).
public struct PairwiseEvaluation: Codable, Sendable, Hashable, Identifiable {
    public enum Winner: String, Codable, Sendable, CaseIterable {
        case a
        case b
        case tie
    }

    public var id: String
    public var requestAID: String
    public var requestBID: String
    public var backendA: BackendID
    public var backendB: BackendID
    public var winner: Winner
    /// True when the reviewer voted without seeing model identities.
    public var blind: Bool
    public var notes: String
    public var judgedBy: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                requestAID: String,
                requestBID: String,
                backendA: BackendID,
                backendB: BackendID,
                winner: Winner,
                blind: Bool,
                notes: String = "",
                judgedBy: String = "local reviewer",
                createdAt: Date = Date()) {
        self.id = id
        self.requestAID = requestAID
        self.requestBID = requestBID
        self.backendA = backendA
        self.backendB = backendB
        self.winner = winner
        self.blind = blind
        self.notes = notes
        self.judgedBy = judgedBy
        self.createdAt = createdAt
    }

    public var winningRequestID: String? {
        switch winner {
        case .a: return requestAID
        case .b: return requestBID
        case .tie: return nil
        }
    }
}