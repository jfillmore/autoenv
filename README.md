# AUTOENV

Shell hacks to define nestable "envs" that automatically declare:

- $PATH hacks for scripts
- aliases
- env vars

... and more!


## Minimalist usage

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

```
# clone the repo
mkdir -p ~/dev && cd ~/dev && git clone https://github.com/jfillmore/autoenv.git

# initialize ourself
source ~/dev/autoenv/autoenv.sh

# setup a home env w/ a handy sync source
yes | ae create ~ home
echo 'https://raw.githubusercontent.com/jfillmore/autoenv-home/' \
    > ~/.autoenv/vars/AUTOENV_SYNC_URL

# sync some useful default stuff
ae reload
(cd ~ && ae sync -v bash vim)

# link autoenv to our new spot that our bash sessions will source
mkdir ~/.bashrc.d && ln -s ~/dev/autoenv/autoenv.sh ~/.bashrc.d/
```
