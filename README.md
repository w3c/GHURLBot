GHURLBot is a GitHub App in the form of an IRC bot. It provides full
URLs when GitHub issues (‘#123’) or users (‘@yyyy’) are mentioned in a
channel on IRC. It is typically known as ‘gb’ on IRC. E.g.:

    <joe> Let's discuss issue #13.
    <gb> https://github.com/xxx/yyy/issues/13 -> #13

Users who have an account on GitHub can also authorize gb to look up,
create, or close issues (or action items) for them. (An ‘action item’
is an issue that has at least one assignee, has a due date, and is
labeled ‘action’.) E.g.:

    <joe> action bert: Save the world. Due next year.
    <gb>Created -> action #42 https://github.com/myorg/myrepo/issues/42
    <joe> gb, list issues with label wontfix
    <gb> Found issues in myorg/myrepo: #41, #40, #27, #26, #25, #23

Instructions for running the bot and descriptions of the command-line
options are included in the `ghurlbot.pl` file. Download the file and
run `perldoc` to see the manual page. (Requires perl.) E.g.:

    perldoc -oman ghurlbot.pl

The interaction with the bot in IRC is documented in
[manual.html](https://w3c.github.io/GHURLBot/manual.html)

