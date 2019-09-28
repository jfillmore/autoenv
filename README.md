# AUTOENV

Shell hacks to define nestable "envs" that automatically declare:

- $PATH hacks for scripts
- aliases
- env vars

... and more!


## Quick start:

```
# snag the script
curl -s \
    -o ~/.autoenv.sh \
    https://raw.githubusercontent.com/jfillmore/autoenv/master/autoenv.sh

# initialize ourself
source ~/.autoenv.sh

# ensure it runs by default for interactive shells
echo 'if [[ "$-" =~ 'i' ]]; then source ~/.auteoenv.sh; fi' >> ~/.bashrc
```


## Advanced usage:

```
# clone the script
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/jfillmore/autoenv.git

# initialize ourself
source ~/dev/autoenv/autoenv.sh

# set ourselves up to sync against an external source
mkdir -p ~/.autoenv/vars/
echo 'https://raw.githubusercontent.com/jfillmore/autoenv-home/' \
    > ~/.autoenv/vars/AUTOENV_SYNC_URL
autoenv add ~ home

# sync some useful default scripts
autoenv sync bash vim

# move autoenv to our new spot that our bash scripts will source from
mv ~/autoenv.sh ~/.bashrc.d/
```
