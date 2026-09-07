# MedSmile: Healthcare Satisfaction Monitoring System  
*An On-Premise Data Warehouse and Business Intelligence Solution*

![Talend](https://img.shields.io/badge/ETL-Talend-blue)  
![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL-darkblue?logo=postgresql&logoColor=white)  
![PowerBI](https://img.shields.io/badge/Visualization-PowerBI-yellow?logo=powerbi&logoColor=black)  
![Status](https://img.shields.io/badge/Project-On--Premise-brightgreen)  

---

## Project Overview

MedSmile is an on-premise healthcare satisfaction monitoring system that consolidates patient surveys, hospital ratings, and operational metrics into a centralized PostgreSQL data warehouse. The system provides healthcare administrators with unified analytics capabilities to improve patient experience and facility performance through OLAP analysis and interactive dashboards.

---

## Table of Contents
- [Problem Definition](#problem-definition)  
- [Business Context](#business-context)  
- [Data Model](#data-model)  
- [Data Warehouse Design](#data-warehouse-design)  
- [ETL Process](#etl-process)  
- [OLAP Operations](#olap-operations)  
- [Power BI Analytics](#power-bi-analytics)  
- [Future Scope](#future-scope)  
- [Tools & Technologies](#tools--technologies)  
- [Project Structure](#project-structure)  
- [References](#references)  

---

## Problem Definition

Healthcare organizations manage fragmented data across multiple systems, including patient satisfaction surveys, facility ratings, and operational metrics. This fragmentation prevents:

- Holistic analysis of patient experience
- Cross-facility performance comparisons
- Identification of underperforming areas
- Data-driven decision making

MedSmile addresses these challenges through a centralized on-premise data warehouse that consolidates healthcare data into a single analytical platform.

---

## Business Context

The system supports four core business functions:

**Hospital Operations**: Centralized facility information enables optimization of staffing, capacity planning, and service delivery.

**Patient Management**: Aggregated survey data supports quality monitoring, readmission tracking, and satisfaction measurement.

**Patient Engagement**: Structured feedback collection enables targeted improvements in communication and service quality.

**Regulatory Reporting**: Unified data infrastructure ensures consistent, auditable reporting for stakeholders and regulators.

The on-premise PostgreSQL deployment supports strict data governance and healthcare compliance requirements.

---

## Data Model

### Source Data

The system integrates five primary data sources:

1. Hospital_Details
2. Location
3. Patient_Details
4. Survey_Details
5. Emergency_Services

Data is sourced from the [US Hospital Customer Satisfaction (2016–2020)](https://www.kaggle.com/datasets/abrambeyer/us-hospital-customer-satisfaction-20162020) dataset with supplementary manually generated columns.

### Relational Schema

- **Hospital_Details**: PatientID, FacilityID, Facility_Name, Phone_Number, Address, Street, City, State, Zipcode, HospitalOwnership, HospitalType
- **Location**: LocationID, City, State, Zipcode, Address, Facility_Name
- **Patient_Details**: PatientID, Patient_Type, Insurance_Type
- **Survey_Details**: SurveyID, PatientID, HCAHPSMeasureID, HCAHPS_Question, HCAHPS_Answer, PatientSurveyStarRating, SurveyResponseRatePercent, NumberofCompletedSurveys
- **Emergency_Services**: ServiceID, ServiceType, Availability, ResponseTime, Capacity

### Entity Relationship Model

The ERD demonstrates key relationships:

- HOSPITAL connects to SURVEY via the HAS relationship
- SURVEY links to SURVEY_DATES through CONDUCTS
- HOSPITAL_RATING captures performance across multiple dimensions
- HOSPITAL receives ratings through CAN_RECEIVE
- Patients participate via COORRESPONDS relationship

---

## Data Warehouse Design

The data warehouse implements a star schema in PostgreSQL.

### Fact Table: Survey_Fact

**Keys**: SurveyFactID (PK), SurveyID, PatientID, LocationID, ServiceID, FacilityID (FKs)

**Measures**: AvgPatientSurveyStarRating, AvgSurveyResponseRatePercent, TotalCompletedSurveys

### Dimension Tables

1. **Hospital_Dimension**: FacilityID, Facility_Name, Phone_Number, Address, City, State, HospitalOwnership, HospitalType

2. **Survey_Dimension**: SurveyID, HCAHPSMeasureID, HCAHPS_Question, HCAHPS_Answer, PatientSurveyStarRating, SurveyResponseRatePercent, NumberofCompletedSurveys, LocationID, FacilityID, PatientID, ServiceID

3. **Location_Dimension**: LocationID, City, County, State, Zipcode, Address, Facility_Name

4. **Patient_Dimension**: PatientID, Patient_Type, Insurance_Type

5. **Emergency_Services_Dimension**: ServiceID, ServiceType, Availability, ResponseTime, Capacity

### Slowly Changing Dimensions

SCD Type 1 is implemented for Facility_Name, HospitalType, and HospitalOwnership attributes. Current values overwrite historical data to maintain current facility information.

---

## ETL Process

ETL operations are implemented in Talend Open Studio, connecting to PostgreSQL via JDBC.

### Dimension Loading

Source tables undergo transformation and loading:
- Hospital_Details → Hospital_Dimension
- Location → Location_Dimension
- Patient_Details → Patient_Dimension
- Survey_Details → Survey_Dimension
- Emergency_Services → Emergency_Services_Dimension

**Transformations Applied**:
- Text trimming and quote removal
- Boolean conversion (YES/NO → 1/0)
- NULL value handling
- Data type conversions

### Fact Table Population

Dimension data is joined using tMap components and loaded into Survey_Fact. Aggregate measures including TotalCompletedSurveys and AveragePatientSurveyStarRating are calculated during the ETL process.

---

## OLAP Operations

The data warehouse supports standard OLAP analytical operations:

1. **Roll-Up**: Average survey rating aggregated by state and facility
2. **Drill-Across**: Survey completion counts correlated with rating averages
3. **Slice**: Identification of facilities with ratings below 3 and response rates under 50%
4. **Roll-Up**: Emergency service availability by geographic region
5. **Drill-Down**: Temporal analysis of survey trends by quarter or year
6. **Roll-Up**: Survey volume aggregation by city and hospital type

---

## Power BI Analytics

### Dashboard Overview

The Power BI dashboard provides real-time analytics through direct connection to the PostgreSQL data warehouse.

### Key Performance Indicators

- **Average Star Rating**: 0.73 - Overall patient satisfaction metric
- **Positive Surveys Percentage**: 6.19% - Proportion of favorable responses
- **Total Surveys**: 71K - Completed patient feedback volume
- **Weighted Response Rate**: 30.64 - Response rate adjusted for survey complexity
- **Facility Satisfaction Score**: 3.24 - Composite performance metric

### Visualizations

**Survey Scores Analysis**: Stacked bar chart comparing patient types (Emergency, Inpatient, Observation, Outpatient) across insurance categories.

**Geographic Distribution**: Horizontal bar chart displaying facility distribution across all 50 U.S. states.

**Location Performance**: Multi-ring donut chart showing survey volumes and positive feedback percentages by location ID.

**Interactive Q&A**: Natural language query interface enabling ad-hoc data exploration.

### Analytical Capabilities

- Cross-dimensional analysis of patient demographics and satisfaction
- Geographic performance benchmarking
- Time-series trend analysis
- Facility-level comparative assessment
- Insurance type impact evaluation

### Technical Implementation

- Direct query mode for real-time data access
- Scheduled refresh capability
- Row-level security for multi-facility environments
- Optimized aggregations for performance
- Mobile-responsive design

---

## Future Scope

### Hospital Rating Expansion

Implementation of additional rating dimensions identified in the ERD:
- Patient Experience Rating
- Timeliness of Care Rating
- Effectiveness of Caring Rating
- Safety of Care Rating
- Mortality Rating
- Readmission Rating
- Efficient Use of Medical Imaging Rating

### Temporal Analytics Enhancement

Integration of the SURVEY_DATES entity for:
- Hierarchical time dimensions (Year, Quarter, Month)
- Time-series analysis
- Seasonal trend identification
- Longitudinal performance tracking

### Historical Tracking

Migration from SCD Type 1 to Type 2 for:
- Ownership transition analysis
- Facility type change tracking
- Organizational impact assessment
- Compliance audit trails

### Advanced Analytics

- Predictive modeling for patient satisfaction
- Natural language processing of survey comments
- Statistical process control for performance monitoring
- Machine learning-based risk prediction

### Data Integration

- Electronic Health Records (EHR) connectivity
- Financial data integration
- External benchmarking sources (CMS Hospital Compare)
- Real-time data streaming capabilities

### Enhanced Governance

- Expanded HIPAA compliance measures
- Automated data quality framework
- Advanced role-based access control
- Comprehensive audit logging

### Platform Enhancements

- Cloud migration path for scalability
- Real-time alert system
- Mobile application development
- Self-service BI capabilities

---

## Tools & Technologies

| Component | Technology | Purpose |
|-----------|-----------|---------|
| ETL | Talend Open Studio | Data extraction, transformation, and loading |
| Database | PostgreSQL | Data warehouse and OLAP operations |
| Visualization | Power BI | Interactive dashboards and reporting |
| Modeling | Star Schema | Dimensional data warehouse design |

---

## Project Structure

```plaintext
MedSmile_Healthcare_Satisfaction_Monitoring/
│
├── Data/
│   ├── Input_data/
│   │   ├── EmergencyServices.csv
│   │   ├── Hospital.csv
│   │   ├── Location.csv
│   │   ├── Patient.csv
│   │   └── Survey.csv
│   │
│   ├── MainDataset/
│   │   └── MainDataset.csv.zip
│   │
│   └── Output_data/
│       ├── EmergencyService_Dimension.csv
│       ├── HospitalDimensions.csv
│       ├── LocationDimensions.csv
│       ├── PatientDimension.csv
│       ├── SurveyTableDimension.csv
│       └── survey_fact_table_20241130001.csv
│
├── DimensionTables/
│   ├── EmergencyServicesDetails_ERDimension.item
│   ├── EmergencyServicesDetails_ERDimension.properties
│   ├── HospitalDetails_HospitalDimension.item
│   ├── HospitalDetails_HospitalDimension.properties
│   ├── LocationTableToLocationDim_0.1.item
│   ├── LocationTableToLocationDim_0.1.properties
│   ├── PatientTable_PatientDim_0.1.item
│   ├── PatientTable_PatientDim_0.1.properties
│   ├── SurveyTableDetailsToSurveyTable.item
│   └── SurveyTableDetailsToSurveyTable.properties
│
├── FactTables/
│   ├── DimensionTablesToSurveyFact_0.1.item
│   └── DimensionTablesToSurveyFact_0.1.properties
│
├── CONCEPTUAL_DATA_WAREHOUSE.pdf
├── ERD_DIAGRAM.png
├── MedSmile_Queries.sql
├── MedSmileHealthcareSatisfactionMonitoringSystem_OnPremise.pdf
└── README.md
```

---

## References

1. [US Hospital Customer Satisfaction Dataset](https://www.kaggle.com/datasets/abrambeyer/us-hospital-customer-satisfaction-20162020) - Kaggle
2. [HCAHPS Survey Information](https://www.cms.gov/Medicare/Quality-Initiatives-Patient-Assessment-Instruments/HospitalQualityInits/HospitalHCAHPS) - CMS
3. [PostgreSQL Documentation](https://www.postgresql.org/docs/)
4. [Talend Open Studio Documentation](https://www.talend.com/products/talend-open-studio/)
5. [Power BI Documentation](https://docs.microsoft.com/en-us/power-bi/)

---

**Author**: Krithika Ravishankar  
**Institution**: Northeastern University  
**Program**: Enterprise Project Management & Data Visualization

*Last Updated: November 2024*