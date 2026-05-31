public enum CalendarScopes {
    public static let readonly = "https://www.googleapis.com/auth/calendar.readonly"
    public static let events = "https://www.googleapis.com/auth/calendar.events"
    public static let all: [String] = [readonly, events]
}
