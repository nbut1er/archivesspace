require_relative "cv_list"
require_relative "agent_handler"
require_relative "container_instance_handler"
require_relative "digital_object_handler"
require_relative "lang_handler"
require_relative "notes_handler"
require_relative "subject_handler"
require_relative "../../../lib/crud_helpers"
require "pp"

# containes classes and methods that might be needed for more than one bulk import converter

# METHOD(s)
def resolves
  ["subjects", "related_resources", "linked_agents",
   "revision_statements",
   "container_locations", "digital_object", "classifications",
   "related_agents", "resource", "parent", "creator",
   "linked_instances", "linked_records", "related_accessions",
   "linked_events", "linked_events::linked_records",
   "linked_events::linked_agents",
   "top_container", "container_profile", "location_profile",
   "owner_repo"]
end

# save (create/update) the archival object, then revive it

def ao_save(ao)
  revived = nil
  begin
    archObj = nil
    if ao.id.nil?
      archObj = ArchivalObject.create_from_json(ao)
    else
      obj = ArchivalObject.get_or_die(ao.id)
      archObj = obj.update_from_json(ao)
    end
    objs = ArchivalObject.sequel_to_jsonmodel([archObj])
    revived = objs[0] if !objs.empty?
  rescue ValidationException => ve
    raise BulkImportException.new(I18n.t("bulk_import.error.ao_validation", :err => ve.errors))
  rescue Exception => e
    Log.error("UNEXPECTED ao save error: #{e.message}\n#{e.backtrace}")
    Log.error(ASUtils.jsonmodels_to_hashes(ao).pretty_inspect) if ao
    raise e
  end
  revived
end

def archival_object_from_ref(ref_id)
  dataset = CrudHelpers.scoped_dataset(ArchivalObject, { :ref_id => ref_id })
  ao = nil
  if !dataset.empty?
    objs = dataset.respond_to?(:all) ? dataset.all : dataset
    jsonms = ArchivalObject.sequel_to_jsonmodel(objs)
    if jsonms.length == 1
      ao = jsonms[0]
    else
      raise BulkImportException.new(I18n.t("bulk_import.error.bad_ao_ref_id", :ref_id => ref_id))
    end
  end
  ao
end

def archival_object_from_ref_or_uri(ref_id, uri)
  ao = nil
  errs = ""
  if uri.nil? && ref_id.nil?
    errs = I18n.t("bulk_import.error.no_uri_or_ref")
  elsif !uri.nil?
    begin
      ao = archival_object_from_uri(uri)
    rescue BulkImportException => e
      errs = e.message
    end
  elsif ao.nil? && !ref_id.nil?
    begin
      ao = archival_object_from_ref(ref_id)
    rescue BulkImportException => e
      errs = "#{errs} #{e.message}"
    end
  end
  { :ao => ao, :errs => errs }
end

# accepts either the full URI or just the ID
def archival_object_from_uri(uri)
  ao = nil
  begin
    uris = uri.split("/")
    aoid = uris.length == 1 ? uri : uris[4]
    ao = ArchivalObject.to_jsonmodel(Integer(aoid))
  rescue
    raise BulkImportException.new(I18n.t("bulk_import.error.bad_ao_uri", :uri => uri))
  end
  ao
end

def resource_match(resource, ead_id, uri)
  if uri.nil? && ead_id.nil?
    raise BulkImportException.new(I18n.t("bulk_import.error.row_missing_ead_uri"))
  end
  match = false
  # try uri first
  if !uri.nil?
    if uri == resource["uri"]
      match = true
    else
      raise BulkImportException.new(I18n.t("bulk_import.error.uri_mismatch", :res_uri => resource[:record_uri], :row_uri => uri))
    end
  elsif !ead_id.nil?
    if ead_id == resource["ead_id"]
      match = true
    else
      raise BulkImportException.new(I18n.t("bulk_import.error.res_ead")) if resource["ead_id"].nil?
      raise BulkImportException.new(I18n.t("bulk_import.error.ead_mismatch", :res_ead => resource["ead_id"], :row_ead => ead_id))
    end
  end
  match
end

# The following methods assume @report is defined, and is a BulkImportReport object
def create_date(dates_label, date_begin, date_end, date_type, expression, date_certainty)
  date_str = "(Date: type:#{date_type}, label: #{dates_label}, begin: #{date_begin}, end: #{date_end}, expression: #{expression})"
  begin
    date_type = @date_types.value(date_type || "inclusive")
  rescue Exception => e
    @report.add_errors(I18n.t("bulk_import.error.date_type", :what => date_type, :date_str => date_str))
  end
  begin
    date = { "date_type" => date_type,
             "label" => @date_labels.value(dates_label || "creation") }
  rescue Exception => e
    @report.add_errors(I18n.t("bulk_import.error.date_label",
                              :what => dates_label, :date_str => date_str))
    #don't bother processsing if the label mis-matches
    return nil
  end

  if date_certainty
    begin
      date["certainty"] = @date_certainty.value(date_certainty)
    rescue Exception => e
      @report.add_errors(I18n.t("bulk_import.error.certainty", :what => e.message, :date_str => date_str))
    end
  end
  date["begin"] = date_begin if date_begin
  date["end"] = date_end if date_end
  date["expression"] = expression if expression
  invalids = JSONModel::Validations.check_date(date)
  unless (invalids.nil? || invalids.empty?)
    err_msg = ""
    invalids.each do |inv|
      err_msg << " #{inv[0]}: #{inv[1]}"
    end
    @report.add_errors(I18n.t("bulk_import.error.invalid_date", :what => err_msg, :date_str => date_str))
    return nil
  end
  if date_type == "single" && !date_end.nil?
    @report.add_errors(I18n.t("bulk_import.warn.single_date_end", :date_str => date_str))
  end
  d = JSONModel(:date).new(date)
end

def handle_notes(ao, hash, dig_obj = false)
  @nh = NotesHandler.new
  publish = ao.publish
  errs = []
  notes_keys = hash.keys.grep(/^n_/)
  if notes_keys
    notes_keys.each do |key|
      unless hash[key].nil?
        content = hash[key]
        type = key.match(/n_(.+)$/)[1]
        pubnote = hash["p_#{type}"]
        if pubnote.nil?
          pubnote = publish
        else
          pubnote = (pubnote == "1")
        end
        begin
          note = @nh.create_note(type, content, pubnote, dig_obj)
          ao.notes.push(note) if !note.nil?
        rescue BulkImportException => bei
          errs.push([bei.message])
        end
      end
    end
  end
  errs
end

def test_exceptions(obj, what = "")
  ret_val = false
  begin
    obj._exceptions
    ret_val = true
  rescue Exception => e
    raise BulkImportException.new("editable?") if e.message.include?("editable?")
    raise e
  end
  ret_val
end

# addition to app/lib/crud_helpers.rb to deal with not having the env hash

module CrudHelpers
  def handle_raw_listing(model, where = {}, current_user)
    dataset = CrudHelpers.scoped_dataset(model, where)
    objs = dataset.respond_to?(:all) ? dataset.all : dataset
    opts = { :calculate_linked_repositories => current_user.can?(:index_system) }

    jsons = model.sequel_to_jsonmodel(objs, opts).map { |json|
      if json.is_a?(JSONModelType)
        json.to_hash(:trusted)
      else
        json
      end
    }
    #   results = resolve_references(jsons, true)
    jsons
  end
end

class BulkImportException < Exception
end

class BulkImportDisambigException < BulkImportException
end

class StopBulkImportException < Exception
end

class BulkImportReport
  require "pp"

  def initialize
    @rows = []
    @current_row = nil
    @terminal_error = ""
    @file_name = nil
    @error_rows = 0
    @terminal_error = nil
  end

  def add_errors(errors)
    @error_rows += 1 if @current_row.errors.empty?
    @current_row.add_errors(errors)
  end

  def add_info(info)
    @current_row.add_info(info)
  end

  def add_archival_object(ao)
    @current_row.archival_object(ao) if ao
  end

  # If we stop processing before getting to the end of the spreadsheet, we want that reported out special
  def add_terminal_error(error, counter)
    if counter
      @terminal_error = I18n.t("bulk_import.error.stopped", row: counter, msg: error)
    else
      @terminal_error = I18n.t("bulk_import.error.initialize", msg: error)
    end
    end_row
  end

  def row_count
    @rows.length
  end

  def end_row
    @rows.push @current_row if @current_row
    @current_row = nil
  end

  attr_reader :file_name

  def new_row(row_number)
    @rows.push @current_row if @current_row
    @current_row = Row.new(row_number)
  end

  def set_file_name(file_name)
    @file_name = file_name || I18n.t("bulk_import.error.file_name")
  end

  attr_reader :rows

  attr_reader :terminal_error

  Row = Struct.new(:archival_object_id, :archival_object_display, :ref_id, :row, :errors, :info) do
    def initialize(row_number)
      self.row = I18n.t("bulk_import.row", row: row_number)
      self.errors = []
      self.info = []
      self.archival_object_id = nil
      self.archival_object_display = nil
      self.ref_id = nil
    end

    # if other structures (top_container, agent, etc.) were created along the way
    def add_info(info)
      self.info.push info
    end

    def add_errors(errors)
      if errors.is_a? Array
        self.errors.concat(errors)
      else
        self.errors.push errors
      end
    end

    def archival_object(ao)
      self.archival_object_id = ao.uri
      self.archival_object_display = ao.display_string
      self.ref_id = ao.ref_id
    end
  end
end

# shamelessly stolen (and adapted) from HM's nla_staff_spreadsheet plugin :-)
class ParentTracker
  require "pp"

  def set_uri(hier, uri)
    @current_hierarchy ||= {}
    @current_hierarchy = Hash[@current_hierarchy.map { |k, v|
                                if k < hier
                                  [k, v]
                                end
                              }.compact]

    # Record the URI of the current record
    @current_hierarchy[hier] = uri
  end

  def parent_for(hier)
    # Level 1 parent may  be a resource record and therefore nil,
    if hier > 0
      parent_level = hier - 1
      @current_hierarchy.fetch(parent_level)
    else
      nil
    end
  end
end