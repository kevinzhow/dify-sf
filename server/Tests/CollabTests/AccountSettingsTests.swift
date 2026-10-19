import CollabCore
import CollabStore
import Foundation
import Testing
@testable import CollabServer

// MARK: - Without a database

/// Protocol 1.12's account settings without Postgres: the profile's validation rules and the change-email mails.
@Suite("Account settings")
struct AccountSettingsUnitTests {
    /// Every value of Dify 1.17.1's time zone list (web/utils/timezone.json): the Preferences page offers exactly these.
    static let difyTimezones = [
        "Pacific/Niue", "Pacific/Midway", "Pacific/Pago_Pago", "Pacific/Rarotonga", "America/Adak", "Pacific/Honolulu",
        "Pacific/Tahiti", "Pacific/Marquesas", "America/Anchorage", "Pacific/Gambier", "America/Los_Angeles",
        "America/Tijuana", "America/Vancouver", "Pacific/Pitcairn", "America/Hermosillo", "America/Edmonton",
        "America/Ciudad_Juarez", "America/Denver", "America/Phoenix", "America/Whitehorse", "America/Belize",
        "America/Chicago", "America/Guatemala", "America/Managua", "America/Mexico_City", "America/Matamoros",
        "America/Costa_Rica", "America/El_Salvador", "America/Regina", "America/Tegucigalpa", "America/Winnipeg",
        "Pacific/Easter", "Pacific/Galapagos", "America/Rio_Branco", "America/Bogota", "America/Havana", "America/Atikokan",
        "America/Cancun", "America/Grand_Turk", "America/Cayman", "America/Jamaica", "America/Nassau", "America/New_York",
        "America/Panama", "America/Port-au-Prince", "America/Toronto", "America/Guayaquil", "America/Lima", "America/Manaus",
        "America/St_Kitts", "America/Blanc-Sablon", "America/Montserrat", "America/Barbados", "America/St_Lucia",
        "America/Port_of_Spain", "America/Martinique", "America/St_Barthelemy", "America/Halifax", "Atlantic/Bermuda",
        "America/St_Vincent", "America/Kralendijk", "America/Guadeloupe", "America/Marigot", "America/Aruba",
        "America/Lower_Princes", "America/Tortola", "America/Dominica", "America/St_Thomas", "America/Grenada",
        "America/Antigua", "America/Puerto_Rico", "America/Santo_Domingo", "America/Anguilla", "America/Thule",
        "America/Curacao", "America/La_Paz", "America/Santiago", "America/Guyana", "America/Asuncion", "America/Caracas",
        "America/St_Johns", "America/Argentina/Buenos_Aires", "America/Sao_Paulo", "Antarctica/Palmer", "America/Punta_Arenas",
        "Atlantic/Stanley", "America/Cayenne", "America/Miquelon", "America/Paramaribo", "America/Montevideo", "America/Nuuk",
        "America/Noronha", "Atlantic/South_Georgia", "Atlantic/Azores", "Atlantic/Cape_Verde", "America/Scoresbysund",
        "Africa/Abidjan", "Africa/Accra", "Africa/Bamako", "Africa/Bissau", "Africa/Conakry", "Africa/Dakar",
        "America/Danmarkshavn", "Europe/Isle_of_Man", "Europe/Dublin", "Africa/Freetown", "Atlantic/St_Helena", "Africa/Lome",
        "Europe/London", "Africa/Monrovia", "Africa/Nouakchott", "Africa/Ouagadougou", "Atlantic/Reykjavik", "Europe/Jersey",
        "Europe/Guernsey", "Africa/Banjul", "Africa/Sao_Tome", "Antarctica/Troll", "Africa/Casablanca", "Africa/El_Aaiun",
        "Atlantic/Canary", "Europe/Lisbon", "Atlantic/Faroe", "Africa/Windhoek", "Africa/Algiers", "Europe/Amsterdam",
        "Europe/Andorra", "Europe/Belgrade", "Europe/Berlin", "Europe/Bratislava", "Europe/Brussels", "Europe/Budapest",
        "Europe/Copenhagen", "Europe/Gibraltar", "Europe/Ljubljana", "Arctic/Longyearbyen", "Europe/Luxembourg",
        "Europe/Madrid", "Europe/Monaco", "Europe/Oslo", "Europe/Paris", "Europe/Podgorica", "Europe/Prague", "Europe/Rome",
        "Europe/San_Marino", "Europe/Malta", "Europe/Sarajevo", "Europe/Skopje", "Europe/Stockholm", "Europe/Tirane",
        "Africa/Tunis", "Europe/Vaduz", "Europe/Vatican", "Europe/Vienna", "Europe/Warsaw", "Europe/Zagreb", "Europe/Zurich",
        "Africa/Bangui", "Africa/Malabo", "Africa/Brazzaville", "Africa/Porto-Novo", "Africa/Douala", "Africa/Kinshasa",
        "Africa/Lagos", "Africa/Libreville", "Africa/Luanda", "Africa/Ndjamena", "Africa/Niamey", "Africa/Bujumbura",
        "Africa/Gaborone", "Africa/Harare", "Africa/Juba", "Africa/Khartoum", "Africa/Kigali", "Africa/Blantyre",
        "Africa/Lubumbashi", "Africa/Lusaka", "Africa/Maputo", "Europe/Athens", "Asia/Beirut", "Europe/Bucharest",
        "Africa/Cairo", "Europe/Chisinau", "Asia/Hebron", "Europe/Helsinki", "Europe/Kaliningrad", "Europe/Kyiv",
        "Europe/Mariehamn", "Asia/Nicosia", "Europe/Riga", "Europe/Sofia", "Europe/Tallinn", "Africa/Tripoli",
        "Europe/Vilnius", "Asia/Jerusalem", "Africa/Johannesburg", "Africa/Mbabane", "Africa/Maseru", "Asia/Kuwait",
        "Asia/Bahrain", "Asia/Baghdad", "Asia/Qatar", "Asia/Riyadh", "Asia/Aden", "Asia/Amman", "Asia/Damascus",
        "Africa/Addis_Ababa", "Indian/Antananarivo", "Africa/Asmara", "Africa/Dar_es_Salaam", "Africa/Djibouti",
        "Africa/Kampala", "Indian/Mayotte", "Africa/Mogadishu", "Indian/Comoro", "Africa/Nairobi", "Europe/Minsk",
        "Europe/Moscow", "Europe/Simferopol", "Antarctica/Syowa", "Europe/Istanbul", "Asia/Tehran", "Asia/Yerevan",
        "Asia/Baku", "Asia/Tbilisi", "Asia/Dubai", "Asia/Muscat", "Indian/Mauritius", "Indian/Reunion", "Europe/Samara",
        "Indian/Mahe", "Asia/Kabul", "Indian/Kerguelen", "Indian/Maldives", "Antarctica/Mawson", "Asia/Karachi",
        "Asia/Dushanbe", "Asia/Ashgabat", "Asia/Tashkent", "Asia/Aqtobe", "Asia/Yekaterinburg", "Asia/Colombo", "Asia/Kolkata",
        "Asia/Kathmandu", "Asia/Dhaka", "Asia/Thimphu", "Asia/Urumqi", "Asia/Almaty", "Indian/Chagos", "Asia/Bishkek",
        "Asia/Omsk", "Antarctica/Vostok", "Indian/Cocos", "Asia/Yangon", "Indian/Christmas", "Antarctica/Davis", "Asia/Hovd",
        "Asia/Bangkok", "Asia/Ho_Chi_Minh", "Asia/Phnom_Penh", "Asia/Vientiane", "Asia/Novosibirsk", "Asia/Jakarta",
        "Australia/Perth", "Asia/Brunei", "Asia/Makassar", "Asia/Macau", "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Irkutsk",
        "Asia/Kuala_Lumpur", "Asia/Manila", "Asia/Singapore", "Asia/Taipei", "Asia/Ulaanbaatar", "Australia/Eucla",
        "Asia/Dili", "Asia/Jayapura", "Asia/Tokyo", "Asia/Pyongyang", "Asia/Seoul", "Pacific/Palau", "Asia/Chita",
        "Australia/Adelaide", "Australia/Darwin", "Australia/Brisbane", "Australia/Sydney", "Pacific/Guam", "Pacific/Saipan",
        "Pacific/Chuuk", "Antarctica/DumontDUrville", "Pacific/Port_Moresby", "Asia/Vladivostok", "Australia/Lord_Howe",
        "Pacific/Bougainville", "Antarctica/Casey", "Pacific/Kosrae", "Pacific/Noumea", "Pacific/Norfolk", "Asia/Sakhalin",
        "Pacific/Guadalcanal", "Pacific/Efate", "Pacific/Fiji", "Pacific/Tarawa", "Pacific/Majuro", "Pacific/Nauru",
        "Pacific/Auckland", "Antarctica/McMurdo", "Asia/Kamchatka", "Pacific/Funafuti", "Pacific/Wake", "Pacific/Wallis",
        "Pacific/Chatham", "Pacific/Apia", "Pacific/Kanton", "Pacific/Fakaofo", "Pacific/Tongatapu", "Pacific/Kiritimati"
    ]

    @Test func timezonesAreIANANames() {
        #expect(Self.difyTimezones.count == 318)
        let refused = Self.difyTimezones.filter { !Routes.validTimezone($0) }
        #expect(refused.isEmpty, "refused: \(refused)")
        for ok in ["UTC", "Etc/GMT+5", "Asia/Shanghai", "Europe/Kyiv", "Asia/Kolkata", "America/Argentina/Buenos_Aires"] { #expect(Routes.validTimezone(ok), "\(ok)") }
        for bad in ["", "Mars/Olympus", "GMT+0800", "asia/shanghai", "Asia/Shanghai ", String(repeating: "A", count: 100)] {
            #expect(!Routes.validTimezone(bad), "\(bad)")
        }
    }

    @Test func languagesAreDifys() {
        #expect(Routes.languages.count == 24)
        #expect(Routes.languages.contains("en-US") && Routes.languages.contains("zh-Hans") && Routes.languages.contains("nl-NL"))
        #expect(!Routes.languages.contains("en") && !Routes.languages.contains("zh-CN"))
    }

    @Test func changeEmailMailsAreDifys() {
        let old = MailTemplates.changeEmail(to: "a@b.io", code: "123456", minutes: 5, newAddress: false, language: "en-US")
        #expect(old.subject == "Check your current email" && old.html.contains("Verify Your Request to Change Email"))
        #expect(old.html.contains(#"class="code">123456<"#) && old.html.contains("valid for the next 5 minutes"))
        let new = MailTemplates.changeEmail(to: "n@b.io", code: "654321", minutes: 5, newAddress: true, language: "ja-JP")
        #expect(new.subject == "Confirm your new email address" && new.to == "n@b.io" && new.html.contains("Confirm Your New Email Address"))
        let zhOld = MailTemplates.changeEmail(to: "a@b.io", code: "111111", minutes: 5, newAddress: false, language: "zh-Hans")
        #expect(zhOld.subject == "检测您现在的邮箱" && zhOld.html.contains("验证您的邮箱变更请求") && zhOld.html.contains("5分钟"))
        let zhNew = MailTemplates.changeEmail(to: "a@b.io", code: "111111", minutes: 5, newAddress: true, language: "zh-Hans")
        #expect(zhNew.subject == "确认您的邮箱地址变更")
        let done = MailTemplates.changeEmailCompleted(to: "n@<b>.io", language: "en-US")
        #expect(done.subject == "Your login email has been changed" && done.html.contains("n@&lt;b&gt;.io"))
        #expect(!done.html.contains(#"class="code""#))
    }
}

// MARK: - Routes

/// Protocol 1.12 against Postgres, the real routes and the stub SMTP server.
@Suite("Account settings routes", .enabled(if: testDbHost != nil))
struct AccountSettingsRouteTests {
    /// Mail through the stub and no send interval (tests send several codes in a row).
    static func mailing(_ port: Int, _ change: (inout ServerConfig) -> Void = { _ in }) -> ServerConfig {
        var cfg = stubMailConfig(port: port)
        cfg.changeEmail.sendIntervalSeconds = 0
        change(&cfg)
        return cfg
    }

    @Test func theProfileSetsNameLanguageAndTimezone() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            let viewer = try await api.member("viewer@example.com", role: "normal", inviter: owner)
            #expect(try await api.patch("/v1/account/profile", #"{"timezone":"Asia/Tokyo"}"#).status == 401)
            let tz = try await api.patch("/v1/account/profile", #"{"timezone":"Asia/Tokyo"}"#, token: owner)
            #expect(tz.status == 200 && tz.str("timezone") == "Asia/Tokyo" && tz.str("name") == "Olivia" && tz.str("role") == "owner")
            let lang = try await api.patch("/v1/account/profile", #"{"interface_language":"zh-Hans"}"#, token: owner)
            #expect(lang.str("interface_language") == "zh-Hans" && lang.str("timezone") == "Asia/Tokyo")
            let both = try await api.patch("/v1/account/profile", #"{"name":"  Olivia K  ","timezone":"UTC"}"#, token: owner)
            #expect(both.str("name") == "Olivia K" && both.str("timezone") == "UTC" && both.str("interface_language") == "zh-Hans")
            let me = try await api.get("/v1/account", token: owner)
            #expect(me.str("name") == "Olivia K" && me.str("timezone") == "UTC" && me.str("interface_language") == "zh-Hans")
            // Nothing given: nothing changes.
            #expect(try await api.patch("/v1/account/profile", "{}", token: owner).str("name") == "Olivia K")
            // Every role sets its own profile; it is the caller's own.
            let v = try await api.patch("/v1/account/profile", #"{"timezone":"Europe/Berlin"}"#, token: viewer.token)
            #expect(v.status == 200 && v.str("timezone") == "Europe/Berlin" && v.str("email") == "viewer@example.com")
            #expect(try await api.get("/v1/account", token: owner).str("timezone") == "UTC")

            for (body, why) in [
                (#"{"interface_language":"en"}"#, "not one of Dify's languages"),
                (#"{"timezone":"Mars/Olympus"}"#, "not a time zone"),
                (#"{"timezone":"GMT+0800"}"#, "not an IANA name"),
                (#"{"name":"Ol"}"#, "name too short"),
                (#"{"name":"0123456789012345678901234567890"}"#, "name too long"),
                (#"{"timezone":null}"#, "null"),
                (#"{"timezone":8}"#, "not a string"),
                (#"{"avatar":"file-id"}"#, "no avatars"),
                (#"{"interface_theme":"dark"}"#, "no stored theme"),
                (#"{"email":"x@example.com"}"#, "unknown member"),
                ("[1]", "not an object"),
            ] {
                let a = try await api.patch("/v1/account/profile", body, token: owner)
                #expect(a.status == 400, "\(why): \(a.text)")
            }
            let unchanged = try await api.get("/v1/account", token: owner)
            #expect(unchanged.str("name") == "Olivia K" && unchanged.str("timezone") == "UTC")
        }
    }

    @Test func withoutMailTheEmailCannotChange() async throws {
        try await withServer { api, _, _ in
            let owner = try await api.setupOwner()
            #expect(try await api.get("/v1/system-features").json["enable_change_email"] == .bool(false))
            let a = try await api.post("/v1/account/change-email", #"{"email":"owner@example.com"}"#, token: owner)
            #expect(a.status == 400 && a.errorCode == "mail_not_configured")
            #expect(try await api.post("/v1/account/change-email", #"{"email":"owner@example.com"}"#).status == 401)
        }
        try await withServer(config: stubMailConfig(port: 1)) { api, _, _ in
            let features = try await api.get("/v1/system-features")
            #expect(features.json["enable_change_email"] == .bool(true))
        }
    }

    @Test func codesToBothAddressesChangeTheEmail() async throws {
        try await withStubSMTP { port, box in
            try await withServer(config: Self.mailing(port)) { api, store, _ in
                let owner = try await api.setupOwner(email: "Owner@Example.com", password: "owner-pass-1")
                let editor = try await api.member("editor@example.com", role: "editor", inviter: owner)
                func send(_ body: String, _ token: String = "") async throws -> API.Answer {
                    try await api.post("/v1/account/change-email", body, token: token.isEmpty ? owner : token)
                }
                func check(_ email: String, _ code: String, _ token: String) async throws -> API.Answer {
                    try await api.post("/v1/account/change-email/validity", #"{"email":"\#(email)","code":"\#(code)","token":"\#(token)"}"#,
                                       token: owner)
                }
                func wrong(_ code: String) -> String { code == "000000" ? "111111" : "000000" }

                // Step 1: a code to the current address (named in any case); another address is refused.
                #expect(try await send(#"{"email":"someone@example.com"}"#).errorCode == "invalid_email")
                #expect(try await send(#"{"email":"not-an-email"}"#).status == 400)
                let first = try await send(#"{"email":"owner@EXAMPLE.com","language":"zh-Hans"}"#)
                #expect(first.status == 200 && first.str("result") == "success")
                let oldMail = try #require(try await box.wait(for: 1).first)
                #expect(oldMail.to == ["Owner@Example.com"] && oldMail.text.contains("验证您的邮箱变更请求"))
                let oldCode = try #require(oldMail.code)
                // The token is the caller's: another member cannot use it.
                let foreign = try await api.post("/v1/account/change-email/validity",
                                                 #"{"email":"owner@example.com","code":"\#(oldCode)","token":"\#(first.str("data"))"}"#,
                                                 token: editor.token)
                #expect(foreign.errorCode == "invalid_token")
                // A code to the new address needs the token of a right code for the old one.
                #expect(try await send(#"{"email":"new@example.com","phase":"new_email"}"#).errorCode == "invalid_token")
                #expect(try await send(#"{"email":"new@example.com","phase":"new_email","token":"\#(first.str("data"))"}"#).errorCode
                        == "invalid_token")
                #expect(try await check("owner@example.com", wrong(oldCode), first.str("data")).errorCode == "email_code_error")
                #expect(try await check("new@example.com", oldCode, first.str("data")).errorCode == "invalid_email")
                let verifiedOld = try await check("Owner@example.com", oldCode, first.str("data"))
                #expect(verifiedOld.status == 200 && verifiedOld.json["is_valid"] == .bool(true) && verifiedOld.str("email") == "owner@example.com")
                // Spent; a verified token is no code token.
                #expect(try await check("owner@example.com", oldCode, first.str("data")).errorCode == "invalid_token")
                #expect(try await check("owner@example.com", oldCode, verifiedOld.str("token")).errorCode == "invalid_token")

                // Step 2: the new address. Taken addresses are named before any code goes out.
                let taken = try await api.post("/v1/account/change-email/check-email-unique", #"{"email":"EDITOR@example.com"}"#, token: owner)
                #expect(taken.status == 400 && taken.errorCode == "email_already_in_use")
                let free = try await api.post("/v1/account/change-email/check-email-unique", #"{"email":"New@Example.com"}"#, token: owner)
                #expect(free.status == 200 && free.str("result") == "success")
                #expect(try await api.post("/v1/account/change-email/check-email-unique", #"{"email":"new@example.com"}"#).status == 401)
                let second = try await send(#"{"email":"New@Example.com","phase":"new_email","token":"\#(verifiedOld.str("token"))"}"#)
                #expect(second.status == 200)
                let newMail = try #require(try await box.wait(for: 2).last)
                #expect(newMail.to == ["new@example.com"] && newMail.subject == "Confirm your new email address")
                let newCode = try #require(newMail.code)
                // The old-address token was replaced by the new one.
                #expect(try await send(#"{"email":"x@example.com","phase":"new_email","token":"\#(verifiedOld.str("token"))"}"#).errorCode
                        == "invalid_token")
                let verifiedNew = try await check("new@example.com", newCode, second.str("data"))
                #expect(verifiedNew.status == 200 && verifiedNew.str("email") == "new@example.com")

                // Step 3: change. Only to the verified address, only with the last token.
                func reset(_ email: String, _ token: String) async throws -> API.Answer {
                    try await api.post("/v1/account/change-email/reset", #"{"new_email":"\#(email)","token":"\#(token)"}"#, token: owner)
                }
                #expect(try await reset("other@example.com", verifiedNew.str("token")).errorCode == "invalid_token")
                #expect(try await reset("new@example.com", verifiedOld.str("token")).errorCode == "invalid_token")
                let changed = try await reset("NEW@example.com", verifiedNew.str("token"))
                #expect(changed.status == 200 && changed.str("email") == "new@example.com" && changed.str("role") == "owner")
                #expect(try await reset("new@example.com", verifiedNew.str("token")).errorCode == "invalid_token")
                let done = try #require(try await box.wait(for: 3).last)
                #expect(done.to == ["new@example.com"] && done.subject == "Your login email has been changed")
                // The session stays; the new address signs in, the old one no more.
                #expect(try await api.get("/v1/account", token: owner).str("email") == "new@example.com")
                #expect(try await api.post("/v1/auth/login", #"{"email":"new@example.com","password":"owner-pass-1"}"#).status == 200)
                #expect(try await api.post("/v1/auth/login", #"{"email":"owner@example.com","password":"owner-pass-1"}"#).status == 401)
                #expect(try await store.emailExists("NEW@example.com"))
            }
        }
    }

    @Test func anAddressTakenMeanwhileIsRefused() async throws {
        try await withStubSMTP { port, box in
            try await withServer(config: Self.mailing(port)) { api, _, _ in
                let owner = try await api.setupOwner()
                let first = try await api.post("/v1/account/change-email", #"{"email":"owner@example.com"}"#, token: owner)
                let c1 = try #require(try await box.wait(for: 1).last?.code)
                let v1 = try await api.post("/v1/account/change-email/validity",
                                            #"{"email":"owner@example.com","code":"\#(c1)","token":"\#(first.str("data"))"}"#, token: owner)
                let second = try await api.post("/v1/account/change-email",
                                                #"{"email":"late@example.com","phase":"new_email","token":"\#(v1.str("token"))"}"#, token: owner)
                let c2 = try #require(try await box.wait(for: 2).last?.code)
                let v2 = try await api.post("/v1/account/change-email/validity",
                                            #"{"email":"late@example.com","code":"\#(c2)","token":"\#(second.str("data"))"}"#, token: owner)
                #expect(v2.status == 200)
                // Someone is invited with that address before the change.
                _ = try await api.member("Late@Example.com", role: "editor", inviter: owner)
                let refused = try await api.post("/v1/account/change-email/reset", #"{"new_email":"late@example.com","token":"\#(v2.str("token"))"}"#,
                                                 token: owner)
                #expect(refused.status == 400 && refused.errorCode == "email_already_in_use")
                #expect(try await api.get("/v1/account", token: owner).str("email") == "owner@example.com")
            }
        }
    }

    @Test func theLimitsAreDifys() async throws {
        try await withStubSMTP { port, box in
            try await withServer(config: Self.mailing(port) { $0.changeEmail.sendIntervalSeconds = 60 }) { api, _, _ in
                let owner = try await api.setupOwner()
                let first = try await api.post("/v1/account/change-email", #"{"email":"owner@example.com"}"#, token: owner)
                #expect(first.status == 200)
                let again = try await api.post("/v1/account/change-email", #"{"email":"owner@example.com"}"#, token: owner)
                #expect(again.status == 429 && again.errorCode == "email_change_rate_limit_exceeded")
                #expect(again.text.contains("Please try again in 1 minutes."))
                let code = try #require(try await box.wait(for: 1).first?.code)
                let wrong = code == "000000" ? "111111" : "000000"
                func check(_ c: String) async throws -> API.Answer {
                    try await api.post("/v1/account/change-email/validity",
                                       #"{"email":"owner@example.com","code":"\#(c)","token":"\#(first.str("data"))"}"#, token: owner)
                }
                // More than five wrong codes lock the address, even for the right code.
                for _ in 0..<6 { #expect(try await check(wrong).errorCode == "email_code_error") }
                let locked = try await check(code)
                #expect(locked.status == 429 && locked.errorCode == "email_change_limit")
            }
        }
    }
}
