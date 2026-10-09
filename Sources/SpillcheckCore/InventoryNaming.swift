import Foundation

/// Readable names derived only from app-controlled rule identities and categories, never from content.
public struct ValueKind: Equatable, Sendable {
    /// A list name, such as "GitHub token".
    public let shortName: String
    /// A detail title, such as "GitHub personal access token".
    public let title: String
    /// The service that issued the credential, when the rule identifies one.
    public let service: String?
    /// Two or three uppercase letters for a compact tile.
    public let monogram: String
    public let category: SecretCategory?

    /// Copy for "Change it at …", naming the place a credential is managed.
    public var servicePhrase: String {
        if let service { return service }
        switch category {
        case .privateKey: return "the servers that trust it"
        case .connectionCredential, .password: return "the system that accepts it"
        case .apiKey, .token, nil: return "the issuing service"
        }
    }

    public init(evidence: [DetectionEvidence], categories: [SecretCategory] = []) {
        let ranked = evidence.sorted {
            ($0.signal == .strong ? 0 : 1, Self.match($0.rule.id) == nil ? 1 : 0, $0.rule.id)
                < ($1.signal == .strong ? 0 : 1, Self.match($1.rule.id) == nil ? 1 : 0, $1.rule.id)
        }
        let category = ranked.first?.category ?? categories.sorted { $0.rawValue < $1.rawValue }.first
        if let rule = ranked.first, let named = Self.match(rule.rule.id) {
            self.init(shortName: named.short, title: named.title, service: named.service, monogram: named.mono, category: category)
        } else {
            let fallback = Self.fallback(category)
            self.init(shortName: fallback.short, title: fallback.title, service: nil, monogram: fallback.mono, category: category)
        }
    }

    /// After content removal only the acknowledgement remains, so the credential type is unknown.
    public static func remembered(_ acknowledgement: ObsoleteAcknowledgement) -> ValueKind {
        let name = acknowledgement == .rotated ? "Rotated value" : "Revoked value"
        return ValueKind(shortName: name, title: name, service: nil, monogram: "↻", category: nil)
    }

    private init(shortName: String, title: String, service: String?, monogram: String, category: SecretCategory?) {
        self.shortName = shortName
        self.title = title
        self.service = service
        self.monogram = monogram
        self.category = category
    }

    private typealias Name = (short: String, title: String, service: String?, mono: String)

    /// Exact identities first, then rule families. Unknown rules fall back to their category.
    private static let exact: [String: Name] = [
        "github-fine-grained-pat": ("GitHub token", "GitHub fine-grained access token", "GitHub", "GH"),
        "github-pat": ("GitHub token", "GitHub personal access token", "GitHub", "GH"),
        "github-oauth": ("GitHub token", "GitHub OAuth token", "GitHub", "GH"),
        "github-app-token": ("GitHub token", "GitHub app token", "GitHub", "GH"),
        "github-refresh-token": ("GitHub token", "GitHub refresh token", "GitHub", "GH"),
        "aws-access-token": ("AWS access key", "AWS access key", "AWS", "AWS"),
        "openai-api-key": ("OpenAI key", "OpenAI API key", "OpenAI", "OA"),
        "anthropic-api-key": ("Anthropic key", "Anthropic API key", "Anthropic", "AN"),
        "anthropic-admin-api-key": ("Anthropic key", "Anthropic admin API key", "Anthropic", "AN"),
        "stripe-access-token": ("Stripe key", "Stripe secret key", "Stripe", "ST"),
        "gcp-api-key": ("Google API key", "Google Cloud API key", "Google Cloud", "GC"),
        "jwt": ("JSON Web Token", "JSON Web Token", nil, "JWT"),
        "generic-api-key": ("API key", "API key in a credential field", nil, "API"),
        "private-key": ("Private key", "Private key", nil, "KEY"),
        "leakret-complete-pem": ("Private key", "Private key", nil, "KEY"),
        "leakret-opaque-bearer": ("Bearer token", "Bearer token in an Authorization header", nil, "BT"),
        "leakret-prose-password": ("Password", "Password written in a message", nil, "PW"),
    ]

    private static let families: [(prefix: String, name: Name)] = [
        ("github-", ("GitHub token", "GitHub token", "GitHub", "GH")),
        ("gitlab-", ("GitLab token", "GitLab access token", "GitLab", "GL")),
        ("aws-", ("AWS access key", "AWS credential", "AWS", "AWS")),
        ("openai-", ("OpenAI key", "OpenAI API key", "OpenAI", "OA")),
        ("anthropic-", ("Anthropic key", "Anthropic API key", "Anthropic", "AN")),
        ("stripe-", ("Stripe key", "Stripe secret key", "Stripe", "ST")),
        ("slack-", ("Slack token", "Slack token", "Slack", "SL")),
        ("gcp-", ("Google credential", "Google Cloud credential", "Google Cloud", "GC")),
        ("npm-", ("npm token", "npm access token", "npm", "NPM")),
        ("pypi-", ("PyPI token", "PyPI upload token", "PyPI", "PY")),
        ("huggingface-", ("Hugging Face token", "Hugging Face access token", "Hugging Face", "HF")),
        ("sendgrid-", ("SendGrid key", "SendGrid API key", "SendGrid", "SG")),
        ("twilio-", ("Twilio key", "Twilio API key", "Twilio", "TW")),
        ("mailgun-", ("Mailgun key", "Mailgun API key", "Mailgun", "MG")),
        ("heroku-", ("Heroku key", "Heroku API key", "Heroku", "HK")),
        ("digitalocean-", ("DigitalOcean token", "DigitalOcean token", "DigitalOcean", "DO")),
        ("azure-", ("Azure credential", "Azure credential", "Azure", "AZ")),
        ("shopify-", ("Shopify token", "Shopify access token", "Shopify", "SH")),
        ("atlassian-", ("Atlassian token", "Atlassian API token", "Atlassian", "AT")),
        ("discord-", ("Discord token", "Discord token", "Discord", "DC")),
        ("telegram-", ("Telegram token", "Telegram bot token", "Telegram", "TG")),
        ("linear-", ("Linear key", "Linear API key", "Linear", "LN")),
    ]

    private static func match(_ id: String) -> Name? {
        if let name = exact[id] { return name }
        if let family = families.first(where: { id.hasPrefix($0.prefix) }) { return family.name }
        if id.contains("credential-uri") || id.contains("connection-string") {
            return ("Database password", "Password in a connection string", nil, "DB")
        }
        if id.contains("private-key") { return ("Private key", "Private key", nil, "KEY") }
        if id.contains("password") { return ("Password", "Password", nil, "PW") }
        return nil
    }

    private static func fallback(_ category: SecretCategory?) -> Name {
        switch category {
        case .apiKey: ("API key", "API key", nil, "API")
        case .token: ("Token", "Token", nil, "TOK")
        case .password: ("Password", "Password", nil, "PW")
        case .privateKey: ("Private key", "Private key", nil, "KEY")
        case .connectionCredential: ("Connection credential", "Credential in a connection string", nil, "DB")
        case nil: ("Detected value", "Detected value", nil, "•")
        }
    }
}

public extension DetectionReason {
    /// Plain-language evidence. Rule identifiers remain available as secondary detail.
    var explanation: String {
        switch self {
        case .recognizedFormat: "Matches a known credential format."
        case .privateKeyBlock: "A complete private key block."
        case .credentialField: "A value assigned to a credential field."
        case .entropy: "A random-looking value in a credential position."
        case .connectionString: "A password inside a connection string."
        case .localRule: "Matched by a local rule with limited context."
        }
    }
}
