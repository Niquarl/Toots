# Last

![Last logo: a viking hat](themes/default/img/favicon.png)

This is a script designed to run on [Gitlab Pages](https://docs.gitlab.com/ce/user/project/pages/index.html).

It fetches toots from [Mastodon](https://github.com/tootsuite/mastodon) and builds a webpage, an atom feed and an epub with them.

Last stands for Let's Aggregate Superb Toots. (Thanks to [@Pouhiou](https://framapiaf.org/@Pouhiou) for the name)

The [logo](https://openclipart.org/detail/267534/viking-hat) comes from [Carolemagnet](https://openclipart.org/user-detail/carolemagnet), which released it in the public domain. Thanks!

## How to use?

Fork this project, modify `last.conf`, then commit and push. Enjoy.

To add new toots, add them in `urls` and then commit and push.

If you want to change the aspect of the generated web page and epub, you can either modify the default theme (you'll have to handle merge conflicts when you upgrade your repo from upstream) or copy the default theme to a new directory in `themes/`, modify it and choose this new theme in the configuration file.

If you want to handle [Markdown syntax](https://daringfireball.net/projects/markdown/syntax) in your toots, you'll need to install pandoc.

## Example

Please, go to <https://luc.frama.io/last/> to see how it looks.

## License

MIT Licence, see the [LICENSE](LICENSE) file for details.

## Author

[Luc Didry](https://fiat-tux.fr). You can support me on [Tipeee](https://tipeee.com/fiat-tux) and [Liberapay](https://liberapay.com/sky).

![Tipeee button](themes/default/img/tipeee-tip-btn.png) ![Liberapay logo](themes/default/img/liberapay.png)
