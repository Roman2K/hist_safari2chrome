require 'sqlite3'
require 'ruby-progressbar'

module SafariHistToChrome
  def self.import(safpath, chromepath, logger: nil, progress: true)
    logger ||= begin
      noop = lambda { |str| }
      Logger.new.tap { |l| l.print = noop }
    end
    safdb = SQLite3::Database.new(safpath)
    chromedb = SQLite3::Database.new(chromepath)
    copier = Copier.new(safdb, chromedb, logger)
    if progress
      pb = ProgressBar.create \
        total: copier.step_count + 1,
        # See http://jrgraphix.net/r/Unicode/2580-259F
        format: "%P% %B %c of %C @ %r/s",
        remainder_mark: "\u{2591}",
        progress_mark: "\u{2588}"
    end
    begin
      if pb
        copier.on_step = lambda { |n| pb.progress += n }
        unless noop && logger.print == noop
          logger.print = lambda { |str| pb.log(str) }
        end
      end
      copier.copy
      dups = remove_duplicates(chromedb, logger)
      pb.progress += 1 if pb
    ensure
      pb.finish if pb
    end
    if pb && dups
      puts "Removed %d duplicates" % dups
    end
  end

  def self.remove_duplicates(chromedb, logger)
    # For a given visit of a URL at a certain time, keep the last created visit
    # record:
    chromedb.execute <<-SQL
      DELETE FROM visits
      WHERE id IN (
        SELECT v.id
        FROM visits v
        LEFT JOIN visits v2
          ON v2.url = v.url
          AND v2.visit_time = v.visit_time
          AND v2.id > v.id
        WHERE v2.id IS NOT NULL
      )
    SQL
    chromedb.changes.tap do |n|
      logger.info "deleted %d duplicates", n
    end
  end

  class Copier
    class URLCreationError < StandardError
    end

    def self.insert_sql(table, attrs)
      query = "INSERT INTO #{table} (#{attrs.keys * ', '})" \
        " VALUES (#{['?'] * attrs.size * ', '})"
      [query, attrs.values]
    end

    def initialize(safdb, chromedb, logger)
      @safdb = safdb
      @chromedb = chromedb
      @logger = logger
    end

    def copy
      SafariURLList.urls(@safdb) do |url|
        @chromedb.transaction do
          begin
            url_status, url_id = find_or_create_url_id(url)
          rescue URLCreationError
            @logger.error "failed to find or create URL %s, skipping", url
            @on_step.call 1 + url.visits.size if @on_step
            next
          end
          @logger.info "URL (%s) %s", url_status, url
          @on_step.call 1 if @on_step
          url.visits.each do |visit|
            @chromedb.execute(*Copier.insert_sql("visits",
              url: url_id,
              visit_time: TimeConv.to_chrome(visit.visit_time),
              from_visit: 0,
              transition: 0x30000008, # See https://goo.gl/W0jK9Y
              segment_id: 0,
              visit_duration: 0
            ))
            @logger.info "visit %p", visit.visit_time
            @on_step.call 1 if @on_step
          end
        end
      end
    end

    def step_count
      @safdb.get_first_value <<-SQL
        SELECT hicnt + hvcnt
        FROM
          (SELECT COUNT(*) hicnt FROM history_items),
          (SELECT COUNT(*) hvcnt FROM history_visits)
      SQL
    end

    def on_step=(block)
      @on_step = block
    end

  private

    def find_or_create_url_id(url)
      if id = @chromedb.get_first_value("SELECT id FROM urls WHERE url = ?", url.url)
        return :existing, id
      end
      unless last_visit = url.visits.last
        raise URLCreationError, "no visits for %s" % url
      end
      @chromedb.execute(*Copier.insert_sql("urls",
        url: url.url,
        title: last_visit.title,
        visit_count: url.visit_count,
        typed_count: 0,
        last_visit_time: TimeConv.to_chrome(last_visit.visit_time),
        hidden: 0,
        favicon_id: 0
      ))
      url_id = @chromedb.last_insert_row_id
      unless url_id > 0
        raise URLCreationError, "invalid last ID: %p" % url_id
      end
      return :new, url_id
    end
  end

  module SafariURLList
    def self.urls(db)
      query = <<-SQL
        SELECT hi.id, hi.url, hv.title, hi.visit_count, hv.visit_time
        FROM history_visits hv
        INNER JOIN history_items hi ON hi.id = hv.history_item
        ORDER BY hi.id, hv.visit_time
      SQL

      last = {}
      def last.reset
        replace visits: []
      end
      def last.build_entry
        return unless key? :hiid
        Entry.new(*values_at(:url, :visit_count, :visits))
      end
      last.reset

      db.execute(query) do |row|
        last_hiid = last[:hiid]
        hiid, url, title, visit_count, visit_time = row
        if last_hiid != hiid
          if entry = last.build_entry
            yield entry
            last.reset
          end
          last.update \
            hiid: hiid,
            url: url,
            visit_count: visit_count
        end
        last[:visits] << VisitEntry.new(TimeConv.from_safari(visit_time), title)
      end
      if entry = last.build_entry
        yield entry
      end
    end

    Entry = Struct.new :url, :visit_count, :visits do
      def to_s
        url.to_s
      end
    end

    VisitEntry = Struct.new :visit_time, :title
  end

  module TimeConv
    def self.from_safari(i)
      Time.at(i + 978307200)
    end

    def self.to_chrome(t)
      ((t.to_f + 11644473600) * 1_000_000).to_i
    end
  end

  class Logger
    def initialize
      @print = $stdout.method(:puts)
    end

    attr_accessor :print

    def warn(msg, *args); log 'WARN', msg, *args end
    def info(msg, *args); log 'INFO', msg, *args end
    def error(msg, *args); log 'ERROR', msg, *args end

  private

    def log(level, msg, *args)
      @print.call "%-5s %s" % [level, msg % args]
    end
  end
end

if $0 == __FILE__
  opts, args = ARGV.partition { |arg| arg =~ /^-/ }
  verbose = !!opts.delete('--verbose')
  progress = !!opts.delete('--progress')
  if !opts.empty?
    raise ArgumentError, "unhandled options: " + opts * ", "
  end
  if args.size != 2
    raise ArgumentError,
      "usage: %s safari.db chrome.db [--verbose --progress]" %
        [File.basename($0)]
  end
  safdb, chromedb, = args
  logger = SafariHistToChrome::Logger.new if verbose
  SafariHistToChrome.import safdb, chromedb,
    logger: logger,
    progress: progress
end
