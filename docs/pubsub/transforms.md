[Docs](../README.md) › [Pub/Sub](README.md) › Message transforms

# Message transforms

A topic or a subscription can run each message through small JavaScript
functions: to drop a field, mask a value, add an attribute, or drop or
refuse the message. Google calls them single message transforms.
Pub/Sub runs them. This client sets them, reads them and changes them,
and runs none, and **neither does the emulator**.

**On this page:** [A function on a topic](#a-function-on-a-topic) ·
[What a function may do](#what-a-function-may-do) ·
[On a subscription](#on-a-subscription) ·
[Changing the list](#changing-the-list) ·
[What is checked before sending](#what-is-checked-before-sending) ·
[Testing a function](#testing-a-function) ·
[What the emulator and production do](#what-the-emulator-and-production-do)

## A function on a topic

<!-- snippet: tests/docs_examples.zig#pubsub-transform-topic -->
```zig
/// Every order leaves the topic without its card number, whoever
/// subscribes. `redact_js` is the source of a function named `redact`.
fn redactOrders(client: *pubsub.Client, redact_js: []const u8) !void {
    var topic = try client.topic("orders").create(.{
        .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{
            .function_name = "redact",
            .code = redact_js,
        } } }},
    });
    defer topic.deinit();
}
```

The code is JavaScript source, kept beside the program with
`@embedFile` or read from a file:

```js
function redact(message, metadata) {
  const order = JSON.parse(message.data);
  delete order.card;
  message.data = JSON.stringify(order);
  message.attributes['redacted'] = 'yes';
  return message;
}
```

- **The function** is called once for each message, with the message
  and what Pub/Sub knows about it. `message.data` is a string and
  `message.attributes` a map of strings. The function changes them in
  place and returns the message, or returns a new object of the same
  two fields. On a topic, where the message has no id yet, `metadata`
  held only an empty `message_id` when measured.
- **Data that is not text** reaches the function as one character a
  byte, and goes out as it came if the function leaves it alone:
  `0xff 0xfe 0x00 0x61` arrived as a string of length 4 and was
  published unchanged.
- **A transform is a kind and a switch.** `MessageTransform.kind` is
  `.javascript_udf`, with the function's name and its code.
  `.disabled = true` keeps it in the list without running it.
- **A topic's transforms run on publish**, in the order of the list,
  before the topic's [schema](schemas.md) is checked and before the
  message is stored: every subscription then gets what they made of it.
- **Google's limits**: five transforms that are not disabled on a topic
  or a subscription, 20 KB of code a function, 500 ms a message, the
  language's built-ins only, and no network.

## What a function may do

| The function | On a topic | On a subscription |
| --- | --- | --- |
| returns the message | published as returned | delivered as returned |
| returns `null` | **the publish succeeds, with a message id**, and the message is not stored | the message is never delivered: Pub/Sub acknowledges it for the subscriber |
| throws | the whole publish is `error.InvalidArgument`, and none of its messages is published | the message is held back and kept: when the function was taken off the subscription, the message arrived 25 seconds later |
| returns anything else, or a message that is not one | as a throw: `error.InvalidArgument` | not measured |
| runs past its time | as a throw: "Execution of JavaScript UDF timed out" | not measured |

What production counts as not a message, each refused in its own words
(measured 2026-10-12): a return value that is no object, a number or
nothing at all among them; an object with neither data nor attributes;
`message.data` that is not a string; and an attribute whose value is not
a string. A function that spun for 1.5 seconds was cut off, and its
publish answered, after 0.6.

- **A dropped message looks published.** The publisher is given an id
  for a message no subscriber will ever see, and nothing in the answer
  tells it apart, so a
  [`Publisher`'s receipt](publishing.md#a-topic-with-transforms)
  resolves with that id too. That is Pub/Sub's design, measured as
  Google documents it.
- **A throw refuses every message of the request**, as a schema's
  refusal does: every message of a `Topic.publish` call, and every
  message that shared a `Publisher`'s batch. The server's words name the
  function and what it threw.

## On a subscription

<!-- snippet: tests/docs_examples.zig#pubsub-transform-subscription -->
```zig
/// Only this subscriber is spared the test orders: its function returns
/// null for them, and Pub/Sub acknowledges them unseen.
fn skipTestOrders(client: *pubsub.Client, skip_js: []const u8) !void {
    var sub = try client.subscription("orders-billing").create(.{
        .topic_id = "orders",
        .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{
            .function_name = "skipTests",
            .code = skip_js,
        } } }},
    });
    defer sub.deinit();
}
```

A subscription's transforms run on delivery, after its
[filter](topics-and-subscriptions.md#subscription-settings) has let the
message through. The message stays in the topic as it was published;
this subscriber alone gets the transformed one. They are on
`SubscriptionConfig`, `SubscriptionInfo` and `SubscriptionUpdate` under
the same name as on a topic's.

## Changing the list

<!-- snippet: tests/docs_examples.zig#pubsub-transform-update -->
```zig
/// A second function after the first, with the first switched off but
/// kept. The list is replaced whole, so it names everything it keeps.
fn addStamp(client: *pubsub.Client, redact_js: []const u8, stamp_js: []const u8) !void {
    var changed = try client.topic("orders").update(.{ .message_transforms = &.{
        .{ .kind = .{ .javascript_udf = .{ .function_name = "redact", .code = redact_js } }, .disabled = true },
        .{ .kind = .{ .javascript_udf = .{ .function_name = "stamp", .code = stamp_js } } },
    } });
    defer changed.deinit();
}

/// Every transform off the topic.
fn untransformed(client: *pubsub.Client) !void {
    var plain = try client.topic("orders").update(.{ .message_transforms = &.{} });
    defer plain.deinit();
}
```

- **The list is the unit.** There is no adding one transform or
  removing one: an update replaces the list, `&.{}` clears it, and
  leaving the field null keeps it. `TopicInfo.message_transforms` and
  `SubscriptionInfo.message_transforms` read it, in the order it runs.
- **Kinds this client does not model.** Pub/Sub has other kinds of
  transform, AI inference among them. One reads as `.other`, in its
  place in the list, with its switch. A list that holds an `.other` is
  refused before sending, in an update and on a create: sent without
  it, the topic would lose it. Change such a list with a tool that
  knows the kind.
- **When a change holds.** Google says a change takes effect within a
  few minutes. Measured once on a topic: a cleared list held 3 seconds
  later, and a function set again first ran after 12 seconds, with
  messages transformed and not by turns for a while after. So a publish
  right after an update may meet either list.

## What is checked before sending

The emulator checks only how many transforms run. So the client checks
what production was measured to refuse, and answers
`error.InvalidArgument` with the reason in `Diagnostics`:

| Rule | Production, measured 2026-10-12 |
| --- | --- |
| At most 5 transforms that are not disabled | "The request exceeds the maximum number of enabled message transforms." |
| A function name that is there | "...a JavaScript UDF with an empty function name." |
| No two functions of one name, disabled or not | "Each JavaScript UDF must have a unique function name.", also when one of the two, or both, are disabled |
| Code that is there, UTF-8, and at most 20,480 bytes | 20,480 bytes are taken and 20,481 refused |
| No kind this client cannot write | not production's rule: the client's own, above |

Left to the server, which answers `error.FailedPrecondition` when the
topic or the subscription is made or changed: code that does not parse,
and code that holds no function of the name given.

## Testing a function

A test against the emulator proves that the settings are sent and read
back. It proves nothing about the function: there every message arrives
untouched, none is dropped and no publish is refused, whatever the code
says. So:

- **Test the function where JavaScript runs.** It is a plain function of
  two arguments, and any JavaScript engine calls it.
- **Test the wiring in production**, on a throwaway topic: publish, pull,
  and look at what arrived.
- **gcloud can run one without publishing**, with
  `gcloud pubsub message-transforms validate` and `test`. They use two
  calls that are in neither Google's API description nor its protocol
  files, so this client does not offer them.

## What the emulator and production do

Measured on 2026-10-12, in production and with emulator 0.8.36. The
client's own checks catch the ones marked *checked*.

| Behavior | Emulator | Production |
| --- | --- | --- |
| A topic's function that rewrites the message | **stored and never run**: the message arrives as published | the message arrives rewritten, with the attributes the function added |
| A topic's function that returns `null` | the message is delivered | the publish answers a message id, and the message is never delivered |
| A topic's function that throws | the publish is taken | the publish is `error.InvalidArgument`, naming the function and the error |
| A subscription's function | every message is delivered untouched | rewritten, dropped or held back, as the function says |
| Code that does not parse, or holds no such function | taken | `error.FailedPrecondition` |
| No function name; two functions of one name | taken | `error.InvalidArgument` (*checked*) |
| A sixth transform that is not disabled | `error.InvalidArgument` | `error.InvalidArgument`, in the same words (*checked*) |
| Code of 20,481 bytes | taken | `error.InvalidArgument` (*checked*) |
| `disabled` | kept and read back | kept and read back, and the function does not run; six transforms with one disabled, and five with seven more disabled, are taken |
| The deprecated `enabled` | read back when `true`, even beside a `disabled` that says the opposite; gone when `false` | the same, and it changes nothing: a function sent with `enabled: false` ran. The client never sends it and does not read it |
| A function that runs past 500 ms, or returns what is no message | not run | the publish is `error.InvalidArgument`, in the words above |
| An update with a list; with an empty one | replaced; cleared | replaced; cleared |

A function may also write data that is not valid UTF-8: a lone
surrogate came out as three bytes that are not, so a subscriber should
not assume text because a function wrote a string.
