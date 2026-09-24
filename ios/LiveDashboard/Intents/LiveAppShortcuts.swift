import AppIntents

struct LiveAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLiveIntent(),
            phrases: [
                "用\(.applicationName)打开\(\.$event)",
                "Open \(\.$event) in \(.applicationName)"
            ],
            shortTitle: "打开演出",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: ReadPerformanceIntent(),
            phrases: [
                "用\(.applicationName)查看\(\.$performance)的时间",
                "Read \(\.$performance) in \(.applicationName)"
            ],
            shortTitle: "查看场次",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: ReadTicketDeadlineIntent(),
            phrases: [
                "用\(.applicationName)查看\(\.$round)的截止时间",
                "Read the deadline for \(\.$round) in \(.applicationName)"
            ],
            shortTitle: "查看截止时间",
            systemImageName: "ticket"
        )
        AppShortcut(
            intent: ShowFollowedLivesIntent(),
            phrases: [
                "用\(.applicationName)列出我关注的演出",
                "List followed lives in \(.applicationName)"
            ],
            shortTitle: "已关注演出",
            systemImageName: "star"
        )
        AppShortcut(
            intent: RefreshLiveIntent(),
            phrases: [
                "用\(.applicationName)刷新\(\.$event)",
                "Refresh \(\.$event) in \(.applicationName)"
            ],
            shortTitle: "刷新演出",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: OrganizeLiveIntent(),
            phrases: [
                "用\(.applicationName)整理\(\.$event)",
                "Organize \(\.$event) in \(.applicationName)"
            ],
            shortTitle: "整理演出",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: SetTicketReminderIntent(),
            phrases: [
                "用\(.applicationName)提醒我\(\.$round)",
                "Remind me about \(\.$round) in \(.applicationName)"
            ],
            shortTitle: "票务提醒",
            systemImageName: "bell"
        )
    }
}
