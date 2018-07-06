require 'fileutils'
require 'json'

class Sppuppet
  # Match regexps
  MERGE_COMMENT = /(:shipit:|:ship:|!merge|🚢)/
  DELETE_BRANCH_COMMENT = /(:scissors:|✂️️)/
  PLUS_VOTE = /^(:?\+1:?|LGTM|\+2|:thumbsup:|👍)/         # Match :+1:, +1, +2 and LGTM
  MINUS_VOTE = /^(:?\-1:?|:thumbsdown:|👎)/             # Match :-1: and -1
  BLOCK_VOTE = /^(:poop:|:hankey:|-2|💩)/ # Blocks merge
  INCIDENT = /jira.*INCIDENT/

  def initialize(settings, client, project, data, event)
    @settings = settings
    @settings['plus_ones_required'] ||= 1
    @settings['owner_plus_ones_required'] ||= 0
    @settings['owners'] ||= []
    @delete_branch = @settings['chop_on_merge'] ||= false
    @client = client
    @project = project
    @data = data
    @event = event
  end

  def run
    case @event
    when 'issue_comment'
      if @data['action'] != 'created'
        # Not a new comment, ignore
        return 200, 'not a new comment, skipping'
      end

      if @data['sender']['login'] == @client.user.login
        return 200, 'Skipping own comment'
      end

      pull_request_id = @data['issue']['number']
      merge_command = MERGE_COMMENT.match(@data['comment']['body'])

      return 200, 'Not a merge comment' unless merge_command

      return maybe_merge(pull_request_id, true, @data['sender']['login'])

    when 'status'
      return 200, 'Merge state not clean' unless @data['state'] == 'success'
      commit_sha = @data['commit']['sha']
      @client.pull_requests(@project).each do |pr|
        return maybe_merge(pr.number, false) if pr.head.sha == commit_sha
      end
      return 200, "Found no pull requests matching #{commit_sha}"

    when 'pull_request'
      # If a new pull request is opened, comment with instructions
      if @data['action'] == 'opened' && @settings['post_instructions']
        issue = @data['number']
        if @settings['owner_plus_ones_required'] > 0
          owners_required_text = " and at least #{@settings['owner_plus_ones_required']} of the owners "
        else
          owners_required_text = ""
        end
        instructions_text = "To merge at least #{@settings['plus_ones_required']} person other than " +
        "the submitter #{owners_required_text}needs to write a comment containing only _+1_ or :+1:.\n" +
        "Then write _!merge_ or :shipit: to trigger merging.\n" +
        "Also write :scissors: and tutter will clean up by deleting your branch after merge."

        comment = @settings['instructions'] ||  instructions_text
        return post_comment(issue, comment)
      else
        return 200, 'Not posting instructions'
      end
    else
      return 200, "Unhandled event type #{@event}"
    end
  end

  def maybe_merge(pull_request_id, merge_command, merger = nil)
    owner_votes = {}
    votes = {}
    incident_merge_override = false
    pr = @client.pull_request @project, pull_request_id

    # We fetch the latest commit and it's date.
    last_commit = @client.pull_request_commits(@project, pull_request_id).last
    last_commit_date = last_commit.commit.committer.date

    comments = @client.issue_comments(@project, pull_request_id)

    # Check each comment for +1 and merge comments
    comments.each do |i|
      # Comment is older than last commit.
      # We only want to check newer comments
      next if last_commit_date > i.created_at

      commenter = i.attrs[:user].attrs[:login]
      # Skip comments from tutter itself
      next if commenter == @client.user.login

      if MERGE_COMMENT.match(i.body)
        merger ||= commenter
        # Count as a +1 if it is not the author
        unless pr.user.login == commenter
          votes[commenter] = 1
          if @settings['owners'].include?(commenter)
            owner_votes[commenter] = 1
          end
        end
      end

      if DELETE_BRANCH_COMMENT.match(i.body)
        @delete_branch = true
      end

      if PLUS_VOTE.match(i.body) && pr.user.login != commenter
        votes[commenter] = 1
        if @settings['owners'].include?(commenter)
          owner_votes[commenter] = 1
        end
      end

      if MINUS_VOTE.match(i.body) && pr.user.login != commenter
        votes[commenter] = -1
        if @settings['owners'].include?(commenter)
          owner_votes[commenter] = -1
        end
      end

      if BLOCK_VOTE.match(i.body)
        msg = 'Commit cannot be merged so long as a -2 comment appears in the PR.'
        return post_comment(pull_request_id, msg)
      end

      if INCIDENT.match(i.body)
        incident_merge_override = true
      end
    end

    if pr.mergeable_state != 'clean' && pr.mergeable_state != 'has_hooks' && !incident_merge_override 
      msg = "Merge state is not clean. Current state: #{pr.mergeable_state}\n"
      reassure = "I will try to merge this for you when the build turn green\n" +
        "If your build fails or becomes stuck for some reason, just say 'rebuild'\n" +
        'If you have an incident and want to skip the tests or the peer review, please post the link to the jira ticket.'
      if merge_command
        return post_comment(pull_request_id, msg + reassure)
      else
        return 200, msg
      end
    end

    return 200, 'No merge comment found' unless merger

    num_votes = votes.values.reduce(0) { |a, e| a + e }
    if num_votes < @settings['plus_ones_required'] && !incident_merge_override
      msg = "Not enough plus ones. #{@settings['plus_ones_required']} required, and only have #{num_votes}"
      return post_comment(pull_request_id, msg)
    end

    num_owner_votes = owner_votes.values.reduce(0) { |a, e| a + e }
    if num_owner_votes < @settings['owner_plus_ones_required'] && !incident_merge_override
      msg = "Not enough plus ones from owners. #{@settings['owner_plus_ones_required']} required, and only have #{num_owner_votes}"
      return post_comment(pull_request_id, msg)
    end

    # TODO: Word wrap description
    merge_msg = <<MERGE_MSG
Title: #{pr.title}
Opened by: #{pr.user.login}
Reviewers: #{votes.keys.join ', '}
Deployer: #{merger}
URL: #{pr.url}
Tests: #{@client.combined_status(@project, pr.head.sha).statuses.map { |s| [s.state, s.description, s.target_url].join(", ") }.join("\n ")}

#{pr.body}
MERGE_MSG
    if incident_merge_override
      @client.add_labels_to_an_issue @project, pull_request_id, ['incident']
    end
    begin
      merge_commit = @client.merge_pull_request(@project, pull_request_id, merge_msg)
      # If a owner posted a chop comment and was successfully merged delete the branch ref
      @client.delete_branch(pr.head.repo.full_name, pr.head.ref) if @delete_branch
    rescue Octokit::MethodNotAllowed => e
      return post_comment(pull_request_id, "Pull request not mergeable: #{e.message}")
    end
    return 200, "merging #{pull_request_id} #{@project}"
  end

  def post_comment(issue, comment)
    begin
      @client.add_comment(@project, issue, comment)
      return 200, "Commented:\n" + comment
    rescue Octokit::NotFound
      return 404, 'Octokit returned 404, this could be an issue with your access token'
    rescue Octokit::Unauthorized
      return 401, "Authorization to #{@project} failed, please verify your access token"
    rescue Octokit::TooManyLoginAttempts
      return 429, "Account for #{@project} has been temporary locked down due to to many failed login attempts"
    end
  end

end
