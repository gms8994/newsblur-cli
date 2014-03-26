newsblur-cli
============

newsblur-cli is a perl script interface to the [NewsBlur API][1]. Because NewsBlur's API is awesomely simple, it makes building applications like this easy.

Once installed, just `./client.pl`. You'll be prompted for your username and password (password not currently starred) on launch.

INSTALL
=======

You'll need a few perl modules:

* [Curses::UI][2]
* [HTML::Restrict][3]

USAGE
=====

You'll get a list of your subscriptions with unread items on the left. Use your keyboard to move up and down through the list. Hit enter to select the feed.
The unread stories will be listed on the top right. Use your keyboard to move up and down through the available stories. Hit enter to see the contents of the story.
Every 10 seconds, the system attempts to sync the stories you've recently read so that you don't see them next time.

You can use the tab key (or shift tab) to cycle through the open windows.

Control-Q will quit the application.

[1]: http://www.newsblur.com/api
[2]: https://metacpan.org/release/Curses-UI
[3]: https://metacpan.org/release/HTML-Restrict
