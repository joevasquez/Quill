//
//  QueueableErrorClassifier.swift
//  HexCore
//
//  Decides whether a thrown error should be queued for retry or treated as
//  permanent. The policy is conservative: we only queue clearly transient
//  errors (network transport failures, 5xx server errors). User-facing
//  errors (permission denied, missing token, validation, user cancellation)
//  are never queued — replaying them later wouldn't change the outcome and
//  would just confuse the user with stale "Saved offline" notices.
//

import Foundation

/// App-defined errors that carry an HTTP status can conform so the
/// classifier can apply the 408/429/5xx rule without knowing the type.
public protocol HTTPStatusCarrying {
  var httpStatusCode: Int? { get }
}

public enum QueueableErrorClassifier {
  /// Returns true when retrying this error after connectivity returns is
  /// likely to succeed.
  public static func isQueueable(_ error: Error) -> Bool {
    // Transport-level failure: timeout, no internet, DNS, etc. Always
    // worth queueing — by definition these are connectivity-related.
    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet,
           .networkConnectionLost,
           .timedOut,
           .cannotFindHost,
           .cannotConnectToHost,
           .dnsLookupFailed,
           .internationalRoamingOff,
           .dataNotAllowed,
           .callIsActive:
        return true
      default:
        // Other URLError codes (cancelled, unsupportedURL, badURL,
        // appTransportSecurityRequiresSecureConnection, etc.) are
        // either user/dev errors or non-recoverable. Don't queue.
        return false
      }
    }

    // Generic NSError covering background URLSession failures Apple
    // surfaces with a different error domain.
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      // Same set of codes as above, mapped via raw values.
      let queueableCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
      ]
      return queueableCodes.contains(nsError.code)
    }

    // App-defined errors that expose their HTTP status (e.g.
    // `LLMTransportError`) get the standard 408/429/5xx rule.
    if let carrier = error as? HTTPStatusCarrying, let status = carrier.httpStatusCode {
      return isQueueable(httpStatus: status)
    }

    // Everything else: we can't safely decide — bias to NOT queueing
    // because a 4xx (client error) replayed will fail the same way.
    return false
  }

  /// Helper for callers that already extracted the HTTP status code.
  /// 5xx → queue (server-side hiccup, retry likely helps).
  /// 408 (Request Timeout) and 429 (Too Many Requests) → also queueable.
  /// Everything else (4xx client errors) → permanent failure, don't queue.
  public static func isQueueable(httpStatus: Int) -> Bool {
    if (500...599).contains(httpStatus) { return true }
    if httpStatus == 408 || httpStatus == 429 { return true }
    return false
  }
}
