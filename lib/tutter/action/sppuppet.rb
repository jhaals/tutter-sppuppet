require 'fileutils'
require 'json'

class Sppuppet

  def initialize(settings, client, project, data, event)
    @settings = settings
    @settings['plus_ones_required'] ||= 1
    @settings['reports_dir'] ||= '/var/lib/tutter/reports'
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

      pull_request_id = @data['issue']['number']

      merge_command = (@data['comment']['body'] == '!merge' ||
        @data['comment']['body'].start_with?(':shipit:'))

      return 200, 'Not a merge comment' unless merge_command

      return maybe_merge(pull_request_id, true)

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
        comment = @settings['instructions'] || "To merge at least #{@settings['plus_ones_required']} person other than the submitter needs to write a comment containing only _+1_ or :+1:. Then write _!merge_ or :shipit: to trigger merging. If your build fails or becomes stuck for some reason, just say _rebuild_."
        return post_comment(issue, comment)
      else
        return 200, 'Not posting instructions'
      end
    else
      return 200, "Unhandled event type #{@event}"
    end
  end

  def maybe_merge(pull_request_id, merge_command)
    votes = {}
    merger = nil
    pr = @client.pull_request @project, pull_request_id

    unless pr.mergeable_state == 'clean'
      msg = "Merge state for is not clean. Current state: #{pr.mergeable_state}\n"
      reassure = "I will try to merge this for you when the builds turn green\n" +
        'If your build fails or becomes stuck for some reason, just say \'rebuild\''
      if merge_command
        return post_comment(pull_request_id, msg + reassure)
      else
        return 200, msg
      end
    end

    # We fetch the latest commit and it's date.
    last_commit = @client.pull_request_commits(@project, pull_request_id).last
    last_commit_date = last_commit.commit.committer.date

    comments = @client.issue_comments(@project, pull_request_id)

    # Check each comment for +1 and merge comments
    comments.each do |i|
      # Comment is older than last commit.
      # We only want to check newer comments
      next if last_commit_date > i.created_at

      if i.body == '!merge' || i.body.start_with?(':shipit:') || i.body.start_with?(':ship:')
        merger ||= i.attrs[:user].attrs[:login]
        # Count as a +1 if it is not the author
        unless pr.user.login == i.attrs[:user].attrs[:login]
          votes[i.attrs[:user].attrs[:login]] = 1
        end
      end

      match = /^:?([+-])1:?/.match(i.body)
      if match
        score = match[1] == '+' ? 1 : -1
        # pull request submitter cant +1
        unless pr.user.login == i.attrs[:user].attrs[:login]
          votes[i.attrs[:user].attrs[:login]] = score
        end
      end

      match = /^(:poop:|:hankey:|-2)/.match(i.body)
      if match
        msg = "Commit cannot be merged so long as a -2 comment appears in the PR."
        return post_comment(pull_request_id, msg)
      end
    end

    return 200, 'No merge comment found' unless merger

    num_votes = votes.values.reduce(0) { |a, e| a + e }
    if num_votes < @settings['plus_ones_required']
      msg = "Not enough plus ones. #{@settings['plus_ones_required']} required, and only have #{num_votes}"
      return post_comment(pull_request_id, msg)
    end

    json = { url: pr.url,
             title: pr.title,
             opened_by: pr.user.login,
             description: pr.body,
             commits: @client.pull_request_commits(@project, pr.number).map { |c| { author: c.author, message: c.commit.message, sha: c.commit.tree.sha } },
             head_sha: pr.head.sha,
             tests: @client.combined_status(@project, pr.head.sha).statuses.map { |s| {state: s.state, url: s.target_url, description: s.description } },
             reviewers: votes.keys,
             deployer: merger }
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
    begin
      merge_commit = @client.merge_pull_request(@project, pull_request_id, merge_msg)
    rescue Octokit::MethodNotAllowed => e
      return post_comment(pull_request_id, "Pull request not mergeable: #{e.message}")
    end
    puts merge_commit.inspect
    json[:merge_sha] = merge_commit.sha
    report_directory = "#{@settings['reports_dir']}/#{merge_commit.sha[0..1]}/#{merge_commit.sha[2..3]}"
    report_path = "#{report_directory}/#{merge_commit.sha}.json"
    if @settings['generate_reports']
      FileUtils.mkdir_p report_directory
      File.open(report_path, 'w') { |f| f.write(JSON.pretty_generate(json)) }
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
