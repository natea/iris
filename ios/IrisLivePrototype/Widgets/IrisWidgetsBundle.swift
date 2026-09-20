//
//  IrisWidgetsBundle.swift
//  IrisWidgets — the widget extension's entry point.
//
//  One extension renders both things the brief asks for, because iOS requires
//  it: the system wakes THIS process to draw the Live Activity when a push
//  arrives, and the same process draws the home-screen widget on its own
//  schedule (LINK_API.md §14.8).
//
//  The extension holds no credential and makes no network call. Everything it
//  knows either arrived inside an ActivityKit push (the Live Activity) or was
//  written to the App Group container by the app (the widget).
//

import SwiftUI
import WidgetKit

@main
struct IrisWidgetsBundle: WidgetBundle {
    var body: some Widget {
        IrisSummaryWidget()
        IrisLiveActivityWidget()
    }
}
