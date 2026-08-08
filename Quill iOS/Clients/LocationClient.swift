//
//  LocationClient.swift
//  Quill (iOS)
//
//  One-shot "where am I, roughly, right now?" helper used when a new note
//  is created. Best-effort — returns nil when the user hasn't granted
//  WhenInUse authorization or the lookup fails.
//

import CoreLocation
import Foundation
import MapKit

@MainActor
final class LocationClient: NSObject {
  static let shared = LocationClient()

  private let manager = CLLocationManager()
  private var pendingContinuation: CheckedContinuation<CLLocation?, Never>?

  override private init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  /// Request a single location fix. Prompts for permission if undetermined.
  /// Returns nil if the user denies, if Location Services is off, or if
  /// the OS times out / errors out.
  func currentPlace() async -> NoteLocation? {
    let status = manager.authorizationStatus

    switch status {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
      // Don't hang forever waiting for the auth dialog; give up after 10s.
      // If the user approves later, a future recording will try again.
      let approved = await waitForAuthorization(timeout: .seconds(10))
      guard approved else { return nil }
    case .authorizedAlways, .authorizedWhenInUse:
      break
    case .denied, .restricted:
      return nil
    @unknown default:
      return nil
    }

    guard let fix = await requestOneShotLocation() else { return nil }

    let placeName = await reverseGeocode(fix)
    return NoteLocation(
      latitude: fix.coordinate.latitude,
      longitude: fix.coordinate.longitude,
      placeName: placeName
    )
  }

  // MARK: - Internals

  /// `requestLocation` promises exactly one delegate callback, but "eventually"
  /// — indoors or with a cold GPS it can sit for a long time, and a dropped
  /// callback would strand the continuation for the life of the process.
  /// Give up after `timeout` and report no location, which callers already
  /// handle. Resuming is guarded by nilling `pendingContinuation`, so the
  /// delegate and the timeout can't both resume it.
  private func requestOneShotLocation(timeout: Duration = .seconds(8)) async -> CLLocation? {
    let timeoutTask = Task { @MainActor in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      self.pendingContinuation?.resume(returning: nil)
      self.pendingContinuation = nil
    }
    defer { timeoutTask.cancel() }

    return await withCheckedContinuation { continuation in
      self.pendingContinuation = continuation
      manager.requestLocation()
    }
  }

  private func waitForAuthorization(timeout: Duration) async -> Bool {
    // Poll at short intervals — CLLocationManager fires its delegate on the
    // main thread, so checking authorizationStatus is cheap.
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
      switch manager.authorizationStatus {
      case .authorizedAlways, .authorizedWhenInUse: return true
      case .denied, .restricted: return false
      case .notDetermined: try? await Task.sleep(for: .milliseconds(200))
      @unknown default: return false
      }
    }
    return false
  }

  private func reverseGeocode(_ location: CLLocation) async -> String? {
    // CLGeocoder was deprecated in iOS 26 in favor of
    // MKReverseGeocodingRequest. Use the new API when available and fall
    // back on older OS versions. Both yield an MKPlacemark / CLPlacemark
    // with the same .subLocality / .locality / .administrativeArea fields
    // we actually care about.
    let placemark: CLPlacemark?
    if #available(iOS 26.0, *) {
      placemark = await mapKitReverseGeocode(location)
    } else {
      placemark = await legacyReverseGeocode(location)
    }
    guard let p = placemark else { return nil }

    // Prefer "Neighborhood, State" → "City, State" → "Country" in that
    // order. That matches how a human would label a note.
    if let neighborhood = p.subLocality, let admin = p.administrativeArea {
      return "\(neighborhood), \(admin)"
    }
    if let city = p.locality, let admin = p.administrativeArea {
      return "\(city), \(admin)"
    }
    if let city = p.locality {
      return city
    }
    return p.country
  }

  @available(iOS 26.0, *)
  private func mapKitReverseGeocode(_ location: CLLocation) async -> CLPlacemark? {
    guard let request = MKReverseGeocodingRequest(location: location) else {
      return nil
    }
    do {
      let mapItems = try await request.mapItems
      // MKMapItem.placemark is an MKPlacemark, which is a CLPlacemark
      // subclass — existing callers that read CLPlacemark fields work
      // unchanged.
      return mapItems.first?.placemark
    } catch {
      return nil
    }
  }

  private func legacyReverseGeocode(_ location: CLLocation) async -> CLPlacemark? {
    do {
      let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
      return placemarks.first
    } catch {
      return nil
    }
  }
}

// MARK: - CLLocationManagerDelegate

extension LocationClient: CLLocationManagerDelegate {
  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    let fix = locations.last
    Task { @MainActor in
      self.pendingContinuation?.resume(returning: fix)
      self.pendingContinuation = nil
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    Task { @MainActor in
      self.pendingContinuation?.resume(returning: nil)
      self.pendingContinuation = nil
    }
  }
}
