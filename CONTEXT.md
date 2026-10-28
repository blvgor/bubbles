<!-- autopilot:glossary -->
# Bubbles

A macOS menu bar app: the day's tasks live on the desktop as soap bubbles and grow more insistent over time. This file collects the project's words that mean something different in everyday speech. The interface is in English and uses these words; dictation can be in Russian or English.

## Language

**Bubble**:
One task of the day on the desktop: a soap bubble with a title, an urgency pill and a time. It has no close button; it can only be removed by closing the task with proof, or by burning it.
_Avoid_: widget, card, tile

**Desk**:
A transparent full-screen window at desktop level: above the icons, below ordinary windows. The bubbles and the microphone live in it; clicks outside a bubble pass through it.
_Avoid_: desktop (that is the name of the screen itself)

**Microphone**:
A round bubble-button at the bottom centre of the desk. Pressing it opens task input; without a connected key that is text input.
_Avoid_: record button

**Ladder**:
The set of steps by which a task becomes more noticeable: background, surfacing, takeover. The user configures or turns off each step.
_Avoid_: escalation, reminders

**Background only**:
The ladder position in which surfacing and takeover are off: the bubbles stay on the desk and show nothing above the windows. This is the default.
_Avoid_: quiet mode

**Surface**:
The "every N minutes" step of the ladder: the top bubble moves to a level above the windows, glows and stands in the centre, and a toast appears next to it. No more than one bubble surfaces at a time; it does not cover the screen.
_Avoid_: notification, push

**Takeover**:
The ladder step M minutes before the deadline: a full-screen window above everything, with the title, a countdown, the sentence field and the hold button. It cannot be closed except through the emergency exit. It is postponed during screen sharing, a full-screen call and Focus mode.
_Avoid_: lock, full-screen notification

**"By" and "At"**:
Two kinds of time on a task. "By 16:00" is a deadline; the takeover prepares for it. "At 12:00" is an event, for example a meeting; only surfacing applies to it.
_Avoid_: due date

**End of day**:
A setting (off / 18 to 22, default 20:00) that serves as the deadline for tasks without "by". It is not midnight and not the end of the calendar day.
_Avoid_: evening, midnight

**Rank**:
The number by which tasks are ordered: urgency matters most, then how close the deadline is, then a bonus for carried-over tasks. The place in the ranking decides the bubble size: the first is the biggest, the last are smaller.
_Avoid_: priority (that is a separate field: "Normal / Important / Urgent")

**"+N"**:
A small bubble at the edge of the desk. There are at most 8 bubbles on the desk; the rest wait in "+N" and float out one by one to replace the closed ones.
_Avoid_: queue, overflow

**Got it**:
The confirmation window before the bubbles are created: a list of tasks in ranking order with editable titles, times and urgency. Until the person confirms the list, nothing appears on the desk.
_Avoid_: preview, parse result

**Unparsed**:
Dictation lines from which the AI could not make a task. They are shown separately so that nothing is lost silently: the person turns them into tasks or deletes them.
_Avoid_: errors, garbage

**Provider**:
The external service that splits speech into tasks: Claude or ChatGPT. The user enters the key. Without a key there is no provider.
_Avoid_: model, API (the model is only a field in the provider's settings)

**Plain tracker**:
The mode without a key: text input, one line is one task exactly as written, with no parsing of time or urgency. There is no dictation in it.
_Avoid_: manual mode, fallback parsing

**Proof**:
The way to close a task: one sentence about what was done (at least 3 characters) and holding the button for 10 seconds. Releasing early resets the fill. After that the bubble pops.
_Avoid_: confirmation, checkmark

**Burn**:
Remove a task without doing it, without closing it with proof. Available only from the full-screen takeover through the emergency exit. The task burns and the streak resets.
_Avoid_: delete, cancel

**Emergency exit**:
The only way out of the takeover without proof: "Burn and exit". It exists because a screen with no exit is dangerous (a call, urgent work), but it costs a task and the streak.
_Avoid_: close, skip

**Streak**:
A counter of consecutive days on which at least one task was closed and nothing was burned. A burned task or a missed day resets it. It is shown in the menu header.
_Avoid_: points

**Carried over**:
An unclosed task from a previous day that is pulled into today with the mark "from yesterday". It can also be moved to tomorrow right away, but only before the takeover begins; then the streak does not suffer.
_Avoid_: leftovers, overdue

**Long task**:
A task that spans several days: it moves from day to day and gets the mark "long · day N". It is set with the "Long" switch or by dictated words: "long task", "for a few days", "this week" (in Russian: «длинная», «долгая», «на несколько дней», «на неделю»).
_Avoid_: project, epic

**In 15 min / 15 more minutes**:
Two different postponements. "In 15 min" postpones the next surfacing. "15 more minutes" extends the takeover and is available once per task.
_Avoid_: remind me later

**Toast**:
A small strip above the microphone with a message and buttons, for example "45 minutes have passed and "…" is still hanging".
_Avoid_: system notification, banner
