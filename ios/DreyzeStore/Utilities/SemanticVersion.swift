import Foundation

public struct SemanticVersion: Comparable, Sendable {
    private enum PrereleaseIdentifier: Sendable {
        case numeric(String)
        case text(String)
    }

    private let core: [String]
    private let prerelease: [PrereleaseIdentifier]?

    public init?(_ value: String) {
        let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawMain = withoutBuild.first, !rawMain.isEmpty else { return nil }
        if withoutBuild.count == 2 {
            let buildIdentifiers = withoutBuild[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !buildIdentifiers.isEmpty,
                  buildIdentifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else {
                return nil
            }
        }
        let parts = rawMain.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(coreParts.count),
              coreParts.allSatisfy(Self.isValidNumericCore) else { return nil }

        var normalizedCore = coreParts.map(String.init)
        if normalizedCore.count == 1 { normalizedCore.append("0") }
        if normalizedCore.count == 2 { normalizedCore.append("0") }
        core = normalizedCore

        if parts.count == 1 {
            prerelease = nil
        } else {
            let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty,
                  labels.allSatisfy(Self.isValidPrereleaseIdentifier) else { return nil }
            prerelease = labels.map { label in
                let identifier = String(label)
                if identifier.allSatisfy(\.isNumber) {
                    return .numeric(identifier)
                }
                return .text(identifier)
            }
        }
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in lhs.core.indices {
            let comparison = compareNumeric(lhs.core[index], rhs.core[index])
            if comparison != 0 { return comparison < 0 }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some(_)):
            return false
        case (.some(_), nil):
            return true
        case let (.some(left), .some(right)):
            for (leftPart, rightPart) in zip(left, right) {
                let comparison = comparePrerelease(leftPart, rightPart)
                if comparison != 0 { return comparison < 0 }
            }
            return left.count < right.count
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    private static func isValidNumericCore(_ value: Substring) -> Bool {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              value.allSatisfy({ $0.isASCII }) else { return false }
        return value.count == 1 || value.first != "0"
    }

    private static func isValidPrereleaseIdentifier(_ value: Substring) -> Bool {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return false
        }
        let isNumeric = value.allSatisfy(\.isNumber)
        return !isNumeric || value.count == 1 || value.first != "0"
    }

    private static func compareNumeric(_ lhs: String, _ rhs: String) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        if lhs == rhs { return 0 }
        return lhs.lexicographicallyPrecedes(rhs) ? -1 : 1
    }

    private static func comparePrerelease(_ lhs: PrereleaseIdentifier, _ rhs: PrereleaseIdentifier) -> Int {
        switch (lhs, rhs) {
        case let (.numeric(left), .numeric(right)):
            return compareNumeric(left, right)
        case (.numeric, .text):
            return -1
        case (.text, .numeric):
            return 1
        case let (.text(left), .text(right)):
            if left == right { return 0 }
            return left.lexicographicallyPrecedes(right) ? -1 : 1
        }
    }
}

public enum VersionComparator {
    private enum BuildToken {
        case numeric(String)
        case text(String)
    }

    public static func compareBuild(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = tokens(lhs)
        let right = tokens(rhs)
        for (leftToken, rightToken) in zip(left, right) {
            let result: ComparisonResult
            switch (leftToken, rightToken) {
            case let (.numeric(a), .numeric(b)):
                result = compareNumeric(a, b)
            case (.numeric, .text): result = .orderedDescending
            case (.text, .numeric): result = .orderedAscending
            case let (.text(a), .text(b)):
                let aa = a.lowercased()
                let bb = b.lowercased()
                result = aa == bb ? .orderedSame : (aa < bb ? .orderedAscending : .orderedDescending)
            }
            if result != .orderedSame { return result }
        }
        if left.count == right.count { return .orderedSame }
        return left.count < right.count ? .orderedAscending : .orderedDescending
    }

    public static func isNewerRelease(
        candidateVersion: String,
        candidateBuild: String,
        installedVersion: String,
        installedBuild: String?
    ) -> Bool {
        guard let candidate = SemanticVersion(candidateVersion),
              let installed = SemanticVersion(installedVersion) else { return false }
        if candidate != installed { return candidate > installed }
        guard let installedBuild, !installedBuild.isEmpty else { return false }
        return compareBuild(candidateBuild, installedBuild) == .orderedDescending
    }

    private static func tokens(_ value: String) -> [BuildToken] {
        guard !value.isEmpty else { return [] }
        var result: [BuildToken] = []
        var current = ""
        var digitKind: Bool?
        for character in value {
            let isDigit = character.isASCII && character.isNumber
            if let digitKind, digitKind != isDigit, !current.isEmpty {
                result.append(token(current, numeric: digitKind))
                current = ""
            }
            current.append(character)
            digitKind = isDigit
        }
        if !current.isEmpty, let digitKind { result.append(token(current, numeric: digitKind)) }
        return result
    }

    private static func token(_ value: String, numeric: Bool) -> BuildToken {
        numeric ? .numeric(value) : .text(value)
    }

    private static func compareNumeric(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = String(lhs.drop(while: { $0 == "0" }))
        let b = String(rhs.drop(while: { $0 == "0" }))
        let aa = a.isEmpty ? "0" : a
        let bb = b.isEmpty ? "0" : b
        if aa.count != bb.count { return aa.count < bb.count ? .orderedAscending : .orderedDescending }
        return aa == bb ? .orderedSame : (aa < bb ? .orderedAscending : .orderedDescending)
    }
}
