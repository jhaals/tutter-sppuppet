# tutter-sppuppet

This action let non collaborators review
and merge code without having more then read access to the project.

1. A pull request get submitted
2. Someone thinks it looks good and adds a _+1_ comment
3. Another person comment _+1_
4. The pull request can be merged by commenting _!merge_ when it has the
desired amount of +1's(configurable)

A pull request will be blocked if it has a _-1_ comment


### tutter.yaml sppuppet specific settings

    action: 'sppuppet'
    action_settings:
    plus_ones_required: 3

### TODO
* whitelist
* blacklist