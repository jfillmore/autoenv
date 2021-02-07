# AUTOENV

![usage info](https://github.com/jfillmore/autoenv/raw/master/ae-usage.png)


## Minimalist Usage

Add autoenv to an otherwise unmodified environment.

```
# snag the script
curl -s \
    -o ~/.autoenv.sh \
    https://raw.githubusercontent.com/jfillmore/autoenv/master/autoenv.sh

# initialize ourself
source ~/.autoenv.sh

# ensure it runs by default for interactive shells
echo 'if [[ "$-" =~ 'i' ]]; then source ~/.autoenv.sh; fi' >> ~/.bashrc
```


## The JKF Way

Initialize things with a nice bash config, vim configs, and usefule scripts.

```
# clone the repo
(mkdir -p ~/dev/jkf && cd ~/dev/jkf && git clone https://github.com/jfillmore/autoenv.git)

# initialize ourself
source ~/dev/jkf/autoenv/autoenv.sh

# setup a home env w/ a handy sync source
yes | ae create ~ home
echo 'https://raw.githubusercontent.com/jfillmore/autoenv-home/master' \
    > ~/.autoenv/vars/AUTOENV_SYNC_URL

# sync some useful default stuff
ae reload
(cd ~ && ae sync -v bash vim)

# link autoenv to our new spot that our bash sessions will source
ln -s ~/dev/jkf/autoenv/autoenv.sh ~/.bashrc.d/

# re-init our shell
. ~/.bashrc
```
