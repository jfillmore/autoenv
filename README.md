# AUTOENV

Quick start:

```
# snag the script
curl -s \
    -o ~/.autoenv.sh \
    https://raw.githubusercontent.com/jfillmore/autoenv/master/autoenv.sh

# ensure it runs by default for interactive shells
echo 'if [[ "$-" =~ 'i' ]]; then source ~/.auteoenv.sh; fi' >> ~/.bashrc

# initialize ourself
source ~/.autoenv.sh

# And then maybe:
mkdir -p ~/.autoenv/vars/
echo 'https://raw.githubusercontent.com/jfillmore/autoenv-home/' \
    > ~/.autoenv/vars/AUTOENV_SYNC_URL
autoenv sync bash vim \
    && mv ~/.autoenv.sh ~/.bashrc.d/
```
