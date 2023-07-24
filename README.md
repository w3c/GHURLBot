GHURLBot is an IRC bot that provides full URLs when GitHub issues
(‘#123’) or users (‘@yyyy’) are mentioned in IRC. It is typically
known as ‘gb’ on IRC. E.g.:

    <joe> Let's discuss issue #13.
    <gb> https://github.com/xxx/yyy/issues/13 -> #13

When started with a GitHub personal access token, it can also
**look up issues** in a GitHub repository, **create new issues and
action items,** **add comments to them,** or **close** them.

Instructions for running the bot and descriptions of the command-line
options are included in the `ghurlbot.pl` file. Download the file and
run `perldoc` to see the manual page. (Requires perl.) E.g.:

    perldoc -oman ghurlbot.pl

The interaction with the bot in IRC is documented in
[manual.html](https://w3c.github.io/GHURLBot/manual.html)

