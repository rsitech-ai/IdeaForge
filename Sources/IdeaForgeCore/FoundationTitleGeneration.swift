import Foundation

#if canImport(FoundationModels) && !os(watchOS)
import FoundationModels
#endif

public struct IdeaTitleGenerationRequest: Equatable, Sendable {
    public var transcript: String
    public var currentTitle: String
    public var localeIdentifier: String

    public init(transcript: String, currentTitle: String, localeIdentifier: String) {
        self.transcript = transcript
        self.currentTitle = currentTitle
        self.localeIdentifier = localeIdentifier
    }
}

public struct IdeaTitleGenerationResult: Equatable, Sendable {
    public var title: String
    public var providerIdentifier: String?

    public init(title: String, providerIdentifier: String? = nil) {
        self.title = title
        self.providerIdentifier = providerIdentifier
    }
}

public enum IdeaTitleGenerationAvailability: Hashable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case frameworkUnavailable
    case operatingSystemUnsupported
}

public protocol IdeaTitleGenerating: Sendable {
    func availability(for localeIdentifier: String) async -> IdeaTitleGenerationAvailability
    func generateTitle(for request: IdeaTitleGenerationRequest) async throws -> IdeaTitleGenerationResult
}

public enum FoundationTitleGenerationError: Error, Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case frameworkUnavailable
    case operatingSystemUnsupported
    case invalidGeneratedTitle
}

public extension FoundationTitleGenerationError {
    var availability: IdeaTitleGenerationAvailability? {
        switch self {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        case .unsupportedLocale: .unsupportedLocale
        case .frameworkUnavailable: .frameworkUnavailable
        case .operatingSystemUnsupported: .operatingSystemUnsupported
        case .invalidGeneratedTitle: nil
        }
    }
}

public struct SystemFoundationTitleGenerator: IdeaTitleGenerating {
    typealias AvailabilityProvider = @Sendable (String) async -> IdeaTitleGenerationAvailability
    typealias GenerationProvider = @Sendable (IdeaTitleGenerationRequest) async throws -> String

    private let availabilityProvider: AvailabilityProvider
    private let generationProvider: GenerationProvider

    public init() {
        self.init(
            availability: Self.systemAvailability(for:),
            generation: Self.generateUsingSystemModel(for:)
        )
    }

    init(
        availability: @escaping AvailabilityProvider,
        generation: @escaping GenerationProvider
    ) {
        availabilityProvider = availability
        generationProvider = generation
    }

    public func availability(for localeIdentifier: String) async -> IdeaTitleGenerationAvailability {
        await availabilityProvider(localeIdentifier)
    }

    public func generateTitle(for request: IdeaTitleGenerationRequest) async throws -> IdeaTitleGenerationResult {
        let currentAvailability = await availability(for: request.localeIdentifier)
        if let unavailableError = Self.error(for: currentAvailability) {
            throw unavailableError
        }

        var boundedRequest = request
        boundedRequest.transcript = Self.titleExcerpt(request.transcript)
        let generatedTitle = try await generationProvider(boundedRequest)
        guard let normalizedTitle = IdeaTitlePolicy.normalizedGeneratedTitle(
            generatedTitle,
            currentTitle: request.currentTitle
        ) else {
            throw FoundationTitleGenerationError.invalidGeneratedTitle
        }

        return IdeaTitleGenerationResult(title: normalizedTitle, providerIdentifier: "apple.foundation-models")
    }

    /// Title generation uses a conservative UTF-8 budget, leaving context for
    /// instructions and structured output. The stored transcript stays intact.
    /// Keep both ends so a concluding correction is not silently discarded.
    private static func titleExcerpt(_ transcript: String) -> String {
        let budget = 2_048
        guard transcript.utf8.count > budget else { return transcript }
        let separator = "\n[Middle omitted from title excerpt]\n"
        let endBudget = (budget - separator.utf8.count) / 2
        func boundedScalars<S: Sequence>(_ scalars: S) -> [Unicode.Scalar]
        where S.Element == Unicode.Scalar {
            var result: [Unicode.Scalar] = []
            var count = 0
            for scalar in scalars {
                let size = scalar.utf8.count
                guard count + size <= endBudget else { break }
                result.append(scalar)
                count += size
            }
            return result
        }
        let beginning = boundedScalars(transcript.unicodeScalars)
        let ending = boundedScalars(transcript.unicodeScalars.reversed()).reversed()
        return String(String.UnicodeScalarView(beginning)) + separator
            + String(String.UnicodeScalarView(ending))
    }

    private static func error(
        for availability: IdeaTitleGenerationAvailability
    ) -> FoundationTitleGenerationError? {
        switch availability {
        case .available:
            nil
        case .deviceNotEligible:
            .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            .appleIntelligenceNotEnabled
        case .modelNotReady:
            .modelNotReady
        case .unsupportedLocale:
            .unsupportedLocale
        case .frameworkUnavailable:
            .frameworkUnavailable
        case .operatingSystemUnsupported:
            .operatingSystemUnsupported
        }
    }

    private static func systemAvailability(
        for localeIdentifier: String
    ) async -> IdeaTitleGenerationAvailability {
        #if canImport(FoundationModels) && !os(watchOS)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default

            switch model.availability {
            case .available:
                return model.supportsLocale(Locale(identifier: localeIdentifier))
                    ? .available
                    : .unsupportedLocale
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            @unknown default:
                return .modelNotReady
            }
        }

        return .operatingSystemUnsupported
        #else
        return .frameworkUnavailable
        #endif
    }

    private static func generateUsingSystemModel(
        for request: IdeaTitleGenerationRequest
    ) async throws -> String {
        #if canImport(FoundationModels) && !os(watchOS)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw FoundationTitleGenerationError.operatingSystemUnsupported
        }

        let session = LanguageModelSession(
            model: .default,
            instructions: "Generate one concise title grounded only in the provided transcript. Do not add facts."
        )
        #if compiler(>=6.4)
        let options = GenerationOptions(samplingMode: .greedy, temperature: 0.1, maximumResponseTokens: 32)
        #else
        let options = GenerationOptions(sampling: .greedy, temperature: 0.1, maximumResponseTokens: 32)
        #endif
        let response = try await session.respond(
            to: Prompt("""
            Write the title in the transcript's language for locale \(request.localeIdentifier).

            Transcript:
            \(request.transcript)
            """),
            generating: FoundationTitlePayload.self,
            options: options
        )
        return response.content.title
        #else
        throw FoundationTitleGenerationError.frameworkUnavailable
        #endif
    }
}

#if canImport(FoundationModels) && !os(watchOS)
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct FoundationTitlePayload: Sendable {
    @Guide(description: "A single specific title, no longer than 80 characters")
    let title: String
}
#endif

public enum IdeaTitlePolicy {
    public static func normalizedGeneratedTitle(_ generatedTitle: String, currentTitle: String) -> String? {
        guard isKnownCapturePlaceholder(currentTitle) else {
            return nil
        }

        let normalizedTitle = normalizedWhitespace(in: generatedTitle)
        guard !normalizedTitle.isEmpty else {
            return nil
        }

        return truncatedAtWordBoundary(normalizedTitle, maximumLength: 80)
    }

    private static let capturePlaceholderTitles: Set<String> = [
        "Watch Idea",
        "Quick captured idea",
        "Mac captured idea",
        "Recovered voice idea",
        "Untitled Idea"
    ]

    private static func isKnownCapturePlaceholder(_ title: String) -> Bool {
        capturePlaceholderTitles.contains(title)
    }

    private static func normalizedWhitespace(in text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func truncatedAtWordBoundary(_ title: String, maximumLength: Int) -> String {
        guard title.count > maximumLength else {
            return title
        }

        let limit = title.index(title.startIndex, offsetBy: maximumLength)
        if title[limit].isWhitespace {
            return String(title[..<limit])
        }

        let prefix = title[..<limit]
        guard let lastWhitespace = prefix.lastIndex(where: \.isWhitespace) else {
            return String(prefix)
        }

        let wordBoundedPrefix = prefix[..<lastWhitespace]
        return wordBoundedPrefix.isEmpty ? String(prefix) : String(wordBoundedPrefix)
    }
}
