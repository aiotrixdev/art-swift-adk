// Sources/ArtAdk/Agentic/ExecutionReference.swift
//
// Agent and orchestrator ids are execution references: the slug the server
// routes on, optionally pinned to a named build.

import Foundation

// `\A` / `\z`: `$` would also accept a trailing newline.
private let executionReferencePattern = try! NSRegularExpression(
    pattern: "\\A[a-z0-9]+(?:-[a-z0-9]+)*(?:@[a-z0-9]{1,64})?\\z"
)

/// Checks that `reference` names an agent or orchestrator the way the
/// server routes it: a lowercase slug (`my-agent`), optionally pinned to a
/// named build (`my-agent@release2`). Build names are 1–64 lowercase
/// letters or digits.
///
/// Returns `reference` unchanged; it is never normalised. Throws
/// `ARTError.invalidArgument` otherwise.
@discardableResult
public func validateExecutionReference(_ reference: String) throws -> String {
    let range = NSRange(reference.startIndex..., in: reference)
    guard executionReferencePattern.firstMatch(in: reference, range: range) != nil else {
        throw ARTError.invalidArgument("Expected a lowercase slug or slug@buildname, got \"\(reference)\"")
    }
    return reference
}
