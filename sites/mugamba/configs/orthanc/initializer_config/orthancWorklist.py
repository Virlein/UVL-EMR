import orthanc
import json
import urllib.request
import urllib.error
import base64

def make_request(url, method='GET', data=None, username=None, password=None):
    req = urllib.request.Request(url, method=method)
    if username and password:
        credentials = base64.b64encode(f'{username}:{password}'.encode()).decode()
        req.add_header('Authorization', f'Basic {credentials}')
    if data:
        req.add_header('Content-Type', 'application/json')
        req.data = json.dumps(data).encode()
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        orthanc.LogError(f'HTTP error {e.code}: {e.reason}')
        raise
    except Exception as e:
        orthanc.LogError(f'Request error: {str(e)}')
        raise

def OnWorkList(answers, query, issuerAet, calledAet):
    queryDicom = query.WorklistGetDicomQuery()
    queryJson = json.loads(orthanc.DicomBufferToJson(
        queryDicom, orthanc.DicomToJsonFormat.SHORT, orthanc.DicomToJsonFlags.NONE, 0))
    orthanc.LogWarning('C-FIND worklist request: %s' % json.dumps(queryJson, indent=4))

    try:
        responseJson = make_request(getWorklistURL, username=worklistUsername, password=worklistPassword)
        orthanc.LogWarning('Response by server: %s' % json.dumps(responseJson))

        for dicomJson in responseJson:
            responseDicom = orthanc.CreateDicom(json.dumps(dicomJson), None, orthanc.CreateDicomFlags.NONE)
            if query.WorklistIsMatch(responseDicom):
                answers.WorklistAddAnswer(query, responseDicom)
    except Exception as e:
        orthanc.LogError('Failed to get worklist: ' + str(e))

def OnChange(changeType, level, resource):
    if changeType != orthanc.ChangeType.STABLE_STUDY:
        return
    try:
        studyJson = json.loads(orthanc.RestApiGet('/studies/' + resource))
        studyTags = studyJson.get('MainDicomTags', {})
        studyInfo = {
            'accessionNumber': studyTags.get('AccessionNumber'),
            'studyInstanceUID': studyTags.get('StudyInstanceUID'),
            'referringPhysicianName': studyTags.get('ReferringPhysicianName'),
            'studyDescription': studyTags.get('StudyDescription'),
            'studyID': studyTags.get('StudyID')
        }

        allSeries = []
        for seriesID in studyJson.get('Series', []):
            seriesJson = json.loads(orthanc.RestApiGet('/series/' + seriesID))
            seriesTags = seriesJson.get('MainDicomTags', {})
            stepID = None
            instanceInfo = {}

            if 'Instances' in seriesJson and seriesJson['Instances']:
                instID = seriesJson['Instances'][0]
                instanceJson = json.loads(orthanc.RestApiGet(f'/instances/{instID}/tags?simplify'))
                instSeq = instanceJson.get('RequestAttributesSequence', [])
                if isinstance(instSeq, list):
                    for item in instSeq:
                        if 'ScheduledProcedureStepID' in item:
                            stepID = item['ScheduledProcedureStepID']
                            break

                instanceInfo = {
                    'patientBirthDate': instanceJson.get('PatientBirthDate'),
                    'patientID': instanceJson.get('PatientID'),
                    'patientName': instanceJson.get('PatientName'),
                    'scheduledProcedureStepID': stepID,
                    'studyInstanceUID': instanceJson.get('StudyInstanceUID'),
                    'numberOfSlices': instanceJson.get('NumberOfSlices'),
                    'scheduledPerformingPhysician': instanceJson.get('PerformingPhysicianName'),
                    'performedProcedureStepDescription': instanceJson.get('PerformedProcedureStepDescription'),
                    'performedProcedureStepStartDate': instanceJson.get('PerformedProcedureStepStartDate'),
                    'performedProcedureStepStartTime': instanceJson.get('PerformedProcedureStepStartTime'),
                    'requestedProcedureDescription': instanceJson.get('RequestedProcedureDescription'),
                }

            seriesInfo = {
                'seriesID': seriesID,
                'modality': seriesTags.get('Modality'),
                'seriesDescription': seriesTags.get('SeriesDescription'),
                'seriesInstanceUID': seriesTags.get('SeriesInstanceUID'),
                'stationName': seriesTags.get('StationName'),
                'parentStudy': studyJson.get('ParentStudy')
            }

            allSeries.append({
                'seriesInfo': seriesInfo,
                'instanceInfo': instanceInfo,
                'scheduledProcedureStepID': stepID
            })

        if any(s['scheduledProcedureStepID'] for s in allSeries):
            payload = {
                'studyInfo': studyInfo,
                'seriesList': allSeries
            }
            orthanc.LogWarning('Payload sent: ' + json.dumps(payload, indent=2))
            make_request(updateRequestStatusURL, method='POST', data=payload,
                        username=worklistUsername, password=worklistPassword)

    except Exception as e:
        orthanc.LogError('Failed to process stable study: ' + str(e))

def getConfigItem(configItemName):
    config = orthanc.GetConfiguration()
    configJson = json.loads(config)
    return configJson[configItemName]

orthanc.RegisterWorklistCallback(OnWorkList)
orthanc.RegisterOnChangeCallback(OnChange)

getWorklistURL = getConfigItem('ImagingWorklistURL')
updateRequestStatusURL = getConfigItem('ImagingUpdateRequestStatus')
worklistUsername = getConfigItem('ImagingWorklistUsername')
worklistPassword = getConfigItem('ImagingWorklistPassword')
