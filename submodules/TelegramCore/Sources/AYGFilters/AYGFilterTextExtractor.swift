import Foundation
import Postbox

// AYG: the haystack a filter's regular expression is run against — a port of
// AyuGram for Android's `AyuMessageUtils.extractAllText`, which is the only
// thing `AyuFilterController` ever matches on.
//
// Android's shape, in order:
//
//   * the rich-message body (`AyuRichMessageTextExtractor`) for a rich message,
//     otherwise `messageObject.messageText` — but not when it is one of the
//     `AttachVideo` / `AttachPhoto` / `Album` placeholders, which say nothing
//     about the message;
//   * the caption;
//   * an open voice transcription;
//   * the content restriction reason;
//   * every `TL_messageEntityTextUrl`'s target, one per line;
//   * the inline keyboard, each button as `<button>title url</button>`;
//   * a `<type>…</type>` trailer.
//
// Three of those do not map one-for-one and are called out where they happen:
// this client has no separate caption (a caption *is* `Message.text`), it has no
// "transcription is open" state to consult, and `MessageObject.type` is an
// Android-side integer with no counterpart here.
//
// The result is a plain `String` and nothing about it is cached: the *result of
// matching* is memoised in `AYGFilterEngine`, keyed by the message's
// `stableVersion`, which covers the same ground and stays correct across edits.
public enum AYGFilterTextExtractor {

    /// The full haystack for one message, or for a grouped album keyed on its
    /// primary message. `AyuMessageUtils.extractAllText`.
    public static func extractAllText(message: Message, groupMessages: [Message]?) -> String {
        var result = ""

        if let groupMessages, !groupMessages.isEmpty {
            for groupMessage in groupMessages {
                AYGFilterTextExtractor.appendBody(of: groupMessage, into: &result)
            }
        } else {
            AYGFilterTextExtractor.appendBody(of: message, into: &result)
        }

        // Only the primary message's entities and keyboard are read, exactly as
        // Android does — `extractAllText` takes one `MessageObject` and appends
        // the group's bodies to it.
        var hasEntities = false
        for attribute in message.attributes {
            guard let attribute = attribute as? TextEntitiesMessageAttribute, !attribute.entities.isEmpty else {
                continue
            }
            hasEntities = true
            for entity in attribute.entities {
                if case let .TextUrl(url) = entity.type {
                    result += "\n"
                    result += url
                }
            }
        }
        if hasEntities {
            result += "\n"
        }

        for attribute in message.attributes {
            guard let attribute = attribute as? ReplyMarkupMessageAttribute, !attribute.rows.isEmpty else {
                continue
            }
            result += "\n"
            for row in attribute.rows {
                for button in row.buttons {
                    result += "<button>"
                    result += button.title
                    result += " "
                    result += AYGFilterTextExtractor.url(of: button.action) ?? ""
                    result += "</button>\n"
                }
            }
        }

        // AYG: Android appends `messageObject.type`, an integer from its own
        // `MessageObject.TYPE_*` table. There is no such number on this side and
        // inventing one would let a filter written on Android — `<type>16</type>`
        // — silently match nothing forever. A symbolic name keeps the capability
        // ("filter every voice message") and fails visibly instead of quietly.
        result += "\n<type>"
        result += AYGFilterTextExtractor.typeName(of: message)
        result += "</type>"

        return result
    }

    // MARK: - One message's own text

    private static func appendBody(of message: Message, into result: inout String) {
        // A rich message carries its body in an InstantPage rather than in
        // `text`; Android reaches for `AyuRichMessageTextExtractor` here.
        var didAppendRichText = false
        for attribute in message.attributes {
            if let attribute = attribute as? RichTextMessageAttribute {
                AYGFilterTextExtractor.append(blocks: attribute.instantPage.blocks, depth: 0, into: &result)
                didAppendRichText = true
            }
        }

        // AYG: this client has no separate caption — `Message.text` is the
        // caption on a media message and the body on a text one — so Android's
        // two appends (`messageText` then `caption`) are one here. The
        // `AttachVideo` / `AttachPhoto` / `Album` placeholders Android has to
        // exclude are its own generated preview strings and do not exist in
        // `Message.text` at all.
        if !didAppendRichText && !message.text.isEmpty {
            result += message.text
            result += "\n"
        }

        for attribute in message.attributes {
            if let attribute = attribute as? AudioTranscriptionMessageAttribute {
                // AYG: Android only reads a transcription while its bubble is
                // expanded (`isVoiceTranscriptionOpen`), which is a view-layer
                // question this seam cannot ask — the filter runs before any
                // bubble exists. A finished transcription is used whenever there
                // is one, which filters strictly more, never less.
                if !attribute.isPending && !attribute.text.isEmpty {
                    result += attribute.text
                    result += "\n"
                }
            } else if let attribute = attribute as? RestrictedContentMessageAttribute {
                for rule in attribute.rules where !rule.text.isEmpty {
                    result += rule.text
                    result += "\n"
                }
            }
        }

        for media in message.media {
            AYGFilterTextExtractor.append(media: media, into: &result)
        }
    }

    // MARK: - Media

    // AYG: Android gets most of this for free because `messageObject.messageText`
    // is already a rendered preview ("📊 Poll · <question>", the webpage title,
    // …). `Message.text` here is only what the user typed, so the same reach
    // needs the media read explicitly. Everything below is text a human can see
    // on the message; no ids, sizes or file paths.
    private static func append(media: Media, into result: inout String) {
        if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
            result += content.url
            result += "\n"
            if content.displayUrl != content.url {
                result += content.displayUrl
                result += "\n"
            }
            if let websiteName = content.websiteName, !websiteName.isEmpty {
                result += websiteName
                result += "\n"
            }
            if let title = content.title, !title.isEmpty {
                result += title
                result += "\n"
            }
            if let author = content.author, !author.isEmpty {
                result += author
                result += "\n"
            }
            if let text = content.text, !text.isEmpty {
                result += text
                result += "\n"
            }
        } else if let poll = media as? TelegramMediaPoll {
            result += poll.text
            result += "\n"
            for option in poll.options {
                result += option.text
                result += "\n"
            }
        } else if let todo = media as? TelegramMediaTodo {
            result += todo.text
            result += "\n"
            for item in todo.items {
                result += item.text
                result += "\n"
            }
        } else if let file = media as? TelegramMediaFile {
            if let fileName = file.fileName, !fileName.isEmpty {
                result += fileName
                result += "\n"
            }
        } else if let contact = media as? TelegramMediaContact {
            result += contact.firstName
            result += " "
            result += contact.lastName
            result += "\n"
            result += contact.phoneNumber
            result += "\n"
        } else if let game = media as? TelegramMediaGame {
            result += game.title
            result += "\n"
            result += game.description
            result += "\n"
        } else if let invoice = media as? TelegramMediaInvoice {
            result += invoice.title
            result += "\n"
            result += invoice.description
            result += "\n"
        }
    }

    // MARK: - Rich messages

    // `AyuRichMessageTextExtractor.appendBlocks`, including its depth cap of 16 —
    // an InstantPage can nest blockquotes and details indefinitely and this runs
    // against every message on screen.
    private static func append(blocks: [InstantPageBlock], depth: Int, into result: inout String) {
        if depth > 16 {
            return
        }
        for block in blocks {
            AYGFilterTextExtractor.append(block: block, depth: depth, into: &result)
        }
    }

    private static func append(block: InstantPageBlock, depth: Int, into result: inout String) {
        if depth > 16 {
            return
        }
        switch block {
        case let .title(text), let .subtitle(text), let .header(text), let .subheader(text),
             let .paragraph(text), let .footer(text), let .kicker(text), let .thinking(text):
            AYGFilterTextExtractor.append(richText: text, into: &result)
        case let .heading(text, _):
            AYGFilterTextExtractor.append(richText: text, into: &result)
        case let .authorDate(author, _):
            AYGFilterTextExtractor.append(richText: author, into: &result)
        case let .preformatted(text, _):
            AYGFilterTextExtractor.append(richText: text, into: &result)
        case let .formula(latex):
            result += latex
            result += "\n"
        case let .anchor(name):
            result += name
            result += "\n"
        case let .blockQuote(blocks, caption, _):
            AYGFilterTextExtractor.append(blocks: blocks, depth: depth + 1, into: &result)
            AYGFilterTextExtractor.append(richText: caption, into: &result)
        case let .pullQuote(text, caption):
            AYGFilterTextExtractor.append(richText: text, into: &result)
            AYGFilterTextExtractor.append(richText: caption, into: &result)
        case let .list(items, _):
            for item in items {
                switch item {
                case let .text(text, _, _):
                    AYGFilterTextExtractor.append(richText: text, into: &result)
                case let .blocks(blocks, _, _):
                    AYGFilterTextExtractor.append(blocks: blocks, depth: depth + 1, into: &result)
                case .unknown:
                    break
                }
            }
        case let .details(title, blocks, _):
            AYGFilterTextExtractor.append(richText: title, into: &result)
            AYGFilterTextExtractor.append(blocks: blocks, depth: depth + 1, into: &result)
        case let .table(title, rows, _, _, _):
            AYGFilterTextExtractor.append(richText: title, into: &result)
            for row in rows {
                for cell in row.cells {
                    if let text = cell.text {
                        AYGFilterTextExtractor.append(richText: text, into: &result)
                    }
                }
            }
        case let .cover(block):
            AYGFilterTextExtractor.append(block: block, depth: depth + 1, into: &result)
        case let .collage(items, caption), let .slideshow(items, caption):
            AYGFilterTextExtractor.append(blocks: items, depth: depth + 1, into: &result)
            AYGFilterTextExtractor.append(caption: caption, into: &result)
        case let .postEmbed(url, _, _, author, _, blocks, caption):
            result += author
            result += "\n"
            result += url
            result += "\n"
            AYGFilterTextExtractor.append(blocks: blocks, depth: depth + 1, into: &result)
            AYGFilterTextExtractor.append(caption: caption, into: &result)
        case let .webEmbed(url, _, _, caption, _, _, _):
            if let url {
                result += url
                result += "\n"
            }
            AYGFilterTextExtractor.append(caption: caption, into: &result)
        case let .image(_, caption, url, _, _):
            if let url {
                result += url
                result += "\n"
            }
            AYGFilterTextExtractor.append(caption: caption, into: &result)
        // AYG: `.document` is 13.0's generic file, split off `.audio` — same caption.
        case let .video(_, caption, _, _, _), let .audio(_, caption), let .document(_, caption):
            AYGFilterTextExtractor.append(caption: caption, into: &result)
        default:
            // `divider`, `map`, `channelBanner`, `relatedArticles`, `unsupported`
            // and anything upstream adds later: no user-visible text worth
            // matching, or none reachable without pulling in a media store.
            break
        }
    }

    private static func append(caption: InstantPageCaption, into result: inout String) {
        AYGFilterTextExtractor.append(richText: caption.text, into: &result)
        AYGFilterTextExtractor.append(richText: caption.credit, into: &result)
    }

    private static func append(richText: RichText, into result: inout String) {
        let text = richText.plainText
        if text.isEmpty {
            return
        }
        result += text
        result += "\n"
    }

    // MARK: - Type trailer

    private static func typeName(of message: Message) -> String {
        for media in message.media {
            if media is TelegramMediaImage {
                return "photo"
            } else if let file = media as? TelegramMediaFile {
                if file.isInstantVideo {
                    return "roundVideo"
                } else if file.isVoice {
                    return "voice"
                } else if file.isVideo {
                    return "video"
                } else if file.isAnimated {
                    return "animation"
                } else if file.isSticker || file.isAnimatedSticker {
                    return "sticker"
                } else if file.isMusic {
                    return "music"
                }
                return "file"
            } else if media is TelegramMediaContact {
                return "contact"
            } else if media is TelegramMediaMap {
                return "location"
            } else if media is TelegramMediaPoll {
                return "poll"
            } else if media is TelegramMediaTodo {
                return "todo"
            } else if media is TelegramMediaGame {
                return "game"
            } else if media is TelegramMediaInvoice {
                return "invoice"
            } else if media is TelegramMediaDice {
                return "dice"
            } else if media is TelegramMediaStory {
                return "story"
            } else if media is TelegramMediaAction {
                return "service"
            } else if media is TelegramMediaWebpage {
                return "webpage"
            }
        }
        for attribute in message.attributes where attribute is RichTextMessageAttribute {
            return "richMessage"
        }
        return "text"
    }

    private static func url(of action: ReplyMarkupButtonAction) -> String? {
        switch action {
        case let .url(url):
            return url
        case let .urlAuth(url, _):
            return url
        default:
            return nil
        }
    }
}
