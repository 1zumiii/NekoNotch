//
//  CalendarKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// Calendar and reminders.
extension Defaults.Keys {
    static let showCalendar = Key<Bool>("showCalendar", default: true)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    static let calendarWeekView = Key<Bool>("calendarWeekView", default: false)
    static let weekStartDay = Key<WeekStartDay>("weekStartDay", default: .system)
    static let joinMeetingOnEventTap = Key<Bool>("joinMeetingOnEventTap", default: true)
}
