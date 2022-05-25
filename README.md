GHURLBot is an IRC bot that provides full URLs when GitHub issues
(‘#123’) or users (‘@yyyy’) are mentioned in IRC. E.g.:

    <joe> Let's discuss issue #13.
    <ghurlbot> https://github.com/xxx/yyy/issues/13 -> #13

When started with an access token for a GitHub account, it can also
look up issue summaries in a GitHub repository, create new issues and
action items, or close them. (This assumes, of course, that the GitHub
repository allows access by the account the bot is using.)

Instructions for running the bot and descriptions of the command-line
options are included in the `ghurlbot.pl` file. Download the file and
run `perldoc` to see the manual page. (Requires perl.) E.g.:

    perldoc -oman ghurlbot.pl

The interaction with the bot in IRC is documented in
[manual.html](https://w3c.github.io/GHURLBot/manual.html)

