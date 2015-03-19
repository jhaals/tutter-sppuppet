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
      pr = @client.pull_request @project, pull_request_id
      votes = {}

      merge = (@data['comment']['body'] == '!merge' ||
        @data['comment']['body'].start_with?(':shipit:'))

      return 200, 'Not a merge comment' unless merge

      unless pr.mergeable_state == 'clean'
        msg = "Merge state for is not clean. Current state: #{pr.mergeable_state}\nHave the tests finished running?"
        @client.add_comment(@project, pull_request_id, msg)
        return 200, msg
      end

      # We fetch the latest commit and it's date.
      last_commit = @client.pull_request_commits(@project, pull_request_id).last
      last_commit_date = last_commit.commit.committer.date

      comments = @client.issue_comments(@project, pull_request_id)

      # Check each comment for +1 and merge comments
      comments.each do |i|
        # Comment is older than last commit.
        # We only want to check for +1 in newer comments
        next if last_commit_date > i.created_at

        match = /^:?([+-])1:?/.match(i.body)
        if match
          score = match[1] == '+' ? 1 : -1
          # pull request submitter cant +1
          unless pr.user.login == i.attrs[:user].attrs[:login]
            votes[i.attrs[:user].attrs[:login]] = score
          end
        end
      end

      num_votes = votes.values.reduce(0) { |a, e| a + e }
      if num_votes < @settings['plus_ones_required']
        msg = "Not enough plus ones. #{@settings['plus_ones_required']} required, and only have #{num_votes}"
        @client.add_comment(@project, pull_request_id, msg)
        return 200, msg
      end

      json = { url: pr.url,
               title: pr.title,
               author: pr.user.login,
               description: pr.body,
               commits: @client.pull_request_commits(@project, pr.number).map { |c| { author: c.author, message: c.commit.message, sha: c.commit.tree.sha } },
               head_sha: pr.head.sha,
               tests: @client.combined_status(@project, pr.head.sha).statuses.map { |s| {state: s.state, url: s.target_url, description: s.description } },
               reviewers: votes.keys,
               deployer: comments.last.user.login }
      # TODO: Word wrap description
      merge_msg = <<MERGE_MSG
Title: #{pr.title}
Description: #{pr.body}
Author: #{pr.user.login}
Reviewers: #{votes.keys.join ', '}
Deployer: #{comments.last.user.login}
URL: #{pr.url}
MERGE_MSG
      begin
        merge_commit = @client.merge_pull_request(@project, pull_request_id, merge_msg)
      rescue Octokit::MethodNotAllowed => e
        return 200, "Pull request not mergeable: #{e.message}"
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
    when 'pull_request'
      # If a new pull request is opened, comment with instructions
      if @data['action'] == 'opened' && @settings['post_instructions']
        issue = @data['number']
        comment = @settings['instructions'] || "To merge at least #{@settings['plus_ones_required']} person other than the submitter needs to write a comment with saying _+1_ or :+1:. Then write _!merge_ or :shipit: to trigger the merging."
        begin
          @client.add_comment(@project, issue, comment)
          return 200, 'Commented!'
        rescue Octokit::NotFound
          return 404, 'Octokit returned 404, this could be an issue with your access token'
        rescue Octokit::Unauthorized
          return 401, "Authorization to #{@project} failed, please verify your access token"
        rescue Octokit::TooManyLoginAttempts
          return 429, "Account for #{@project} has been temporary locked down due to to many failed login attempts"
        end
      else
        return 200, 'Not posting instructions'
      end
    else
      return 200, "Unhandled event type #{@event}"
    end
  end
end
