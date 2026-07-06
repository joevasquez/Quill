//
//  OnDeviceModelClient.swift
//  Quill (macOS)
//
//  Thin wrapper around Apple's on-device Foundation Models framework
//  (macOS 26+, Apple Intelligence). Used for the agent's background
//  memory-extraction pass so that learning from dictations costs nothing
//  and never leaves the Mac; cloud LLMs remain the engine for action
//  parsing, where quality matters most.
//
//  Compiles to a no-op (isAvailable == false) on SDKs/machines without
//  the framework, so every call site needs a cloud fallback path.
//

import Foundation
import HexCore
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

private let onDeviceLogger = HexLog.aiProcessing

enum OnDeviceModel {
  static var isAvailable: Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      return SystemLanguageModel.default.availability == .available
    }
    #endif
    return false
  }

  /// One-shot completion: system instructions + user message → raw text.
  /// Returns nil when the framework/model is unavailable — callers fall
  /// back to their cloud path.
  static func complete(systemPrompt: String, userMessage: String) async -> String? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
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
