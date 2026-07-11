//
//  IOSOnDeviceModel.swift
//  Quill (iOS)
//
//  Thin wrapper around Apple's on-device Foundation Models framework
//  (iOS 26+, Apple Intelligence) — the iOS twin of the macOS
//  `OnDeviceModel`. Used two ways:
//  1. Memory extraction always prefers it (free, private, offline).
//  2. Text cleanup + note titles FALL BACK to it when the user has no
//     API key and isn't on Pro — the core note flow works out of the
//     box on Apple Intelligence phones with zero setup.
//
//  Compiles to a no-op (isAvailable == false) on SDKs/devices without
//  the framework, so every call site needs its existing path intact.
//

import Foundation
import HexCore
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

private let onDeviceLogger = HexLog.aiProcessing

enum IOSOnDeviceModel {
  static var isAvailable: Bool {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      return SystemLanguageModel.default.availability == .available
    }
    #endif
    return false
  }

  /// One-shot completion: system instructions + user message → raw text.
  /// Returns nil when the framework/model is unavailable — callers fall
  /// back to their cloud path (or surface the missing-key error).
  static func complete(systemPrompt: String, userMessage: String) async -> String? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      guard SystemLanguageModel.default.availability == .available else { return nil }
      do {
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: userMessage)
        onDeviceLogger.info("On-device model completed (\(response.content.count, privacy: .public) chars)")
        return response.content
      } catch {
        onDeviceLogger.warning("On-device model failed, falling back to cloud: \(error.localizedDescription, privacy: .public)")
        return nil
      }
    }
    #endif
    return nil
  }
}
